using System.Diagnostics;
using ServiceLib.Common;
using ServiceLib.Models.Dto;
using ServiceLib.Services;
using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;
using V2rayM.Domain.Runtime;
using v2rayN.WebAPI.Launcher;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private sealed class ApplicationUpdateAdapter(V2rayRuntime owner, bool preRelease, bool useProxy) : IApplicationUpdateRuntime
    {
        private WebUpdateReleaseCheck? check;
        public bool IsStopping => owner._operations.IsStopping;
        public async ValueTask<IUpdateOperationLease> EnterAsync() => await owner._operations.EnterExclusiveAsync(
            owner._operations.ShutdownToken, allowReadOnlyObservations: true);
        public async Task<ApplicationUpdateCheck> CheckAsync(CancellationToken token)
        {
            check = await owner.CheckWebUpdateReleaseAsync(preRelease, useProxy, token);
            Volatile.Write(ref owner._latestWebUpdateVersion, check.Version);
            return new(!string.IsNullOrWhiteSpace(check.Error) ? UpdateDecision.Failed
                : check.IsUpdateAvailable ? UpdateDecision.Available : UpdateDecision.Current, check.Version, check.Error ?? check.Detail);
        }
        public async Task<IApplicationUpdateArtifact> StageAsync(CancellationToken token) =>
            await owner.StageWebUpdateAsync(check ?? throw new InvalidOperationException("The update was not checked."), useProxy, token, batch: false);
        public Task HandoffAsync(IApplicationUpdateArtifact artifact, CancellationToken token) =>
            owner.ApplyStagedWebUpdateAsync((WebUpdateStage)artifact, token, batch: false);
        public void Cleanup(IApplicationUpdateArtifact artifact) => CleanupWebUpdateStage((WebUpdateStage)artifact);
        public void Publish(ApplicationUpdatePhase phase, string? version, string? detail) => owner.PublishWebUpdateProgress(phase switch
        {
            ApplicationUpdatePhase.Checking => "checking", ApplicationUpdatePhase.Completed => "completed",
            ApplicationUpdatePhase.AwaitingValidation => "awaiting-validation", _ => "failed",
        }, phase != ApplicationUpdatePhase.Checking, phase == ApplicationUpdatePhase.Completed, detail, version);
        public void Log(string message) => owner.AddLog("update", message);
    }

    private sealed class ApplicationPackageStaging : IApplicationPackageStaging<WebUpdateStage>
    {
        private readonly V2rayRuntime owner;
        private readonly WebUpdateManifest manifest;
        private readonly WebUpdatePackage package;
        private readonly bool useProxy, batch;
        private readonly string archivePath, packageDirectory, candidateDirectory, backupDirectory, installDirectory;
        public ApplicationPackageStaging(V2rayRuntime owner, WebUpdateReleaseCheck check, bool useProxy, bool batch)
        {
            this.owner = owner; this.useProxy = useProxy; this.batch = batch;
            if (check.Manifest is null || check.Package is null)
                throw new InvalidDataException("The v2rayN.WebAPI update manifest or runtime package was not checked.");
            manifest = check.Manifest;
            package = check.Package;
            var deployment = owner.GetWebUpdateDeployment();
            if (!deployment.CanInstall) throw new InvalidOperationException(deployment.InstallReasonKey ?? "Web update installation is unavailable.");

            var id = Guid.NewGuid().ToString("N");
            archivePath = Utils.GetTempPath($"web-update-{id}.zip");
            packageDirectory = Utils.GetTempPath($"web-update-stage-{id}");
            var executablePath = Environment.ProcessPath
                ?? throw new InvalidOperationException("The current Web executable path is unavailable.");
            installDirectory = Path.GetDirectoryName(Path.GetFullPath(executablePath))
                ?? throw new InvalidOperationException("The current Web executable has no install directory.");
            var installParent = Path.GetDirectoryName(installDirectory)
                ?? throw new InvalidOperationException("The current Web install directory has no parent.");
            candidateDirectory = Path.Combine(installParent, $".v2rayn-WebAPI-candidate-{id}");
            backupDirectory = Path.Combine(installParent, $".v2rayn-WebAPI-backup-{id}");
        }
        public async Task DownloadAsync(CancellationToken cancellationToken)
        {
            owner.PublishWebUpdateProgress("downloading", false, false, null, manifest.Version, batch);
            var downloader = new DownloadService();
            var downloadFailure = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
            downloader.Error += (_, args) => downloadFailure.TrySetResult(args.GetException());
            downloader.UpdateCompleted += (_, progress) =>
                owner.PublishWebUpdateProgress("downloading", false, false, progress.Msg, manifest.Version, batch);
            await downloader.DownloadFileAsync(new FileDownloadRequest
            {
                FileUrl = package.Url,
                FilePath = archivePath,
                DisplayFileName = Path.GetFileName(archivePath),
            }, useProxy, cancellationToken);
            if (downloadFailure.Task.IsCompletedSuccessfully)
                throw new IOException("The v2rayN.WebAPI package download failed.", await downloadFailure.Task);
            if (!File.Exists(archivePath)) throw new IOException("The v2rayN.WebAPI package download did not produce an archive.");
        }
        public async Task VerifyAsync(CancellationToken cancellationToken)
        {
            owner.PublishWebUpdateProgress("verifying", false, false, null, manifest.Version, batch);
            var identity = await WebUpdatePackageStager.VerifyAndExtractAsync(
                archivePath, packageDirectory, manifest, package, cancellationToken);
            if (identity.Rid != WebBuildIdentity.Current.Rid)
                throw new InvalidDataException("The staged v2rayN.WebAPI package has the wrong runtime identifier.");
        }
        public void PrepareCandidate()
        {
            owner.PublishWebUpdateProgress("staged", false, false, "The app-only package passed SHA-256, RID, identity, and archive checks.",
                manifest.Version, batch);
            CopyVerifiedWebApp(packageDirectory, candidateDirectory, package.Rid);
        }
        public WebUpdateStage Complete() => new(archivePath, packageDirectory, candidateDirectory, backupDirectory,
            installDirectory, manifest, package);
        public void Cleanup() => CleanupWebUpdateStageFiles(archivePath, packageDirectory, candidateDirectory);
        public void Log(string message) => owner.AddLog("update", message);
    }

    private sealed class ApplicationUpdateHandoff : IApplicationUpdateHandoff
    {
        private readonly V2rayRuntime owner;
        private readonly WebUpdateStage stage;
        private readonly bool batch;
        private readonly RuntimeRestartIntent runtimeIntent;
        private readonly NativeWebUpdatePlan plan;
        private readonly string runtimeIntentPath, planPath;
        public ApplicationUpdateHandoff(V2rayRuntime owner, WebUpdateStage stage, bool batch)
        {
            this.owner = owner; this.stage = stage; this.batch = batch;
            var current = owner.CurrentCoreRuntime;
            var wasRunning = owner.HasTrackedCoreProcesses
                && current.State is CoreRuntimeState.Running or CoreRuntimeState.Faulted;
            runtimeIntent = new RuntimeRestartIntent(wasRunning, wasRunning ? current.ProfileId : null)
            {
                Reason = "Web application update",
            };
            runtimeIntentPath = WebUpdateRuntimeStatePath;
            var progressPath = Utils.GetTempPath(WebUpdateProgressFile);
            planPath = Utils.GetTempPath($"web-update-plan-{Guid.NewGuid():N}.json");
            var hostArguments = GetCurrentHostArguments();
            // Never stop the current instance before its listener configuration has a
            // loopback HTTP probe: the detached helper verifies the replacement (and its
            // rollback) through that exact endpoint.
            if (!WebProbeUriResolver.TryResolve(owner._configuration, out var probeEndpoints))
            {
                throw new InvalidOperationException(
                    "The current listener configuration has no loopback HTTP health endpoint, so the update cannot be verified safely.");
            }
            plan = new NativeWebUpdatePlan(
                stage.InstallDirectory,
                stage.CandidateDirectory,
                stage.BackupDirectory,
                Path.Combine(Utils.StartupPath(), "v2rayN.WebAPI.instance.lock"),
                probeEndpoints.HealthUri.ToString(),
                hostArguments,
                stage.Manifest.Version,
                stage.Manifest.Commit,
                stage.Package.Rid,
                WebBuildIdentity.Current.Version,
                runtimeIntentPath,
                progressPath,
                wasRunning);
        }
        public bool OwnershipTransferred => stage.TransferredToHelper;
        public Task WriteIntentAsync() => WriteRuntimeIntentAsync(runtimeIntentPath, runtimeIntent);
        public Task WritePlanAsync() => WriteNativeWebUpdatePlanAsync(planPath, plan);
        public void LaunchHelper()
        {
            var executablePath = Environment.ProcessPath
                ?? throw new InvalidOperationException("The native Web executable path is unavailable.");
            ProcessStartInfo startInfo;
            string? isolatedWindowsHelper = null;
            if (OperatingSystem.IsLinux())
            {
                var setsid = LinuxXdgBrowserOpener.FindExecutable("setsid")
                    ?? throw new InvalidOperationException("The setsid executable is required for a native Web update.");
                startInfo = new ProcessStartInfo
                {
                    FileName = setsid,
                    WorkingDirectory = stage.InstallDirectory,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
                startInfo.ArgumentList.Add(executablePath);
            }
            else if (OperatingSystem.IsWindows())
            {
                // The Windows process image is locked while running. Use a sibling copy as the
                // detached update worker so it can replace the installed executable after the
                // Web host releases its instance lock.
                isolatedWindowsHelper = NativeWebUpdateHelper.CreateIsolatedHelperExecutable(executablePath);
                startInfo = new ProcessStartInfo
                {
                    FileName = isolatedWindowsHelper,
                    WorkingDirectory = stage.InstallDirectory,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                };
            }
            else
            {
                throw new PlatformNotSupportedException("Native Web self-update is supported on Linux and Windows x64.");
            }
            startInfo.ArgumentList.Add("--apply-WebAPI-update");
            startInfo.ArgumentList.Add(planPath);
            Process helper;
            try
            {
                helper = Process.Start(startInfo)
                    ?? throw new InvalidOperationException("The native Web update helper could not be started.");
            }
            catch
            {
                if (isolatedWindowsHelper is not null) TryDeleteFile(isolatedWindowsHelper);
                throw;
            }
            using (helper) { stage.TransferredToHelper = true; }
        }
        public void PublishStopping() => owner.PublishWebUpdateProgress("stopping", false, false,
            "All network operations and package verification completed before Web/Core shutdown.", stage.Manifest.Version, batch);
        public void StopHost() => owner._lifetime.StopApplication();
        public Task DeleteIntentAsync() => DeleteRuntimeIntentAsync(runtimeIntentPath);
        public void DeletePlan() => TryDeleteFile(planPath);
        public void Log(string message) => owner.AddLog("update", message);
    }
}
