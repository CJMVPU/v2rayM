using V2rayM.Application.Updates;
using V2rayM.Domain.Runtime;
using System.Text.Json;
using ServiceLib.Common;
using ServiceLib.Models.Dto;
using ServiceLib.Services;
using v2rayN.WebAPI.Contracts;
using v2rayN.WebAPI.Launcher;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private const string WebUpdateProgressFile = "WebAPI-update-progress.json";
    private string? _latestWebUpdateVersion;

    public WebUpdateTargetView GetWebUpdateTarget()
    {
        var deployment = GetWebUpdateDeployment();
        var build = WebBuildIdentity.Current;
        var selected = Config.CheckUpdateItem.SelectedCoreTypes;
        var supportedRid = WebUpdatePackageStager.IsSupportedRid(build.Rid);
        var runtimeInstallReason = GetWebUpdateRuntimeInstallReason();
        var canInstall = deployment.CanInstall && runtimeInstallReason is null;
        return new WebUpdateTargetView(
            WebUpdateTarget,
            build.Version,
            build.Commit,
            build.BuildDate,
            build.Rid,
            ToDeploymentName(deployment.Kind),
            supportedRid,
            deployment.CanCheck,
            canInstall,
            supportedRid && (selected?.Contains(WebUpdateTarget, StringComparer.Ordinal) ?? true),
            !supportedRid ? "maintenance.webUpdateUnsupported" : deployment.InstallReasonKey ?? runtimeInstallReason,
            Volatile.Read(ref _latestWebUpdateVersion) ?? _updateProgress.GetValueOrDefault(WebUpdateTarget)?.Version);
    }

    public async Task<ApiEnvelope<WebUpdateCheckView>> CheckWebUpdateAsync(
        bool? preRelease,
        bool? useProxy,
        CancellationToken cancellationToken)
    {
        var check = await CheckWebUpdateReleaseAsync(
            GetUpdatePreRelease(WebUpdateTarget, preRelease),
            useProxy ?? Config.CheckUpdateItem.UpdateViaProxy,
            cancellationToken);
        Volatile.Write(ref _latestWebUpdateVersion, check.Version);
        var deployment = GetWebUpdateDeployment();
        var view = new WebUpdateCheckView(
            check.IsUpdateAvailable,
            WebBuildIdentity.Current.Version,
            WebBuildIdentity.Current.Commit,
            WebBuildIdentity.Current.Rid,
            check.Version,
            check.Commit,
            deployment.CanInstall && GetWebUpdateRuntimeInstallReason() is null,
            deployment.InstallReasonKey ?? GetWebUpdateRuntimeInstallReason(),
            check.Error ?? check.Detail);
        if (!string.IsNullOrWhiteSpace(check.Error))
        {
            AddLog("update", $"v2rayN.WebAPI update check failed: {check.Error}");
            return ApiEnvelope<WebUpdateCheckView>.Fail("web_update_check_failed", ApiMessageKeys.WebUpdateCheckFailed, view);
        }
        return ApiEnvelope<WebUpdateCheckView>.Ok(view,
            check.IsUpdateAvailable ? ApiMessageKeys.CoreUpdateAvailable : ApiMessageKeys.CoreUpdateCurrent);
    }

    public OperationView StartWebUpdate(bool? preRelease = null, bool? useProxy = null)
    {
        if (!GetWebUpdateDeployment().CanInstall)
        {
            return OperationView.Fail("web_update_install_unsupported", GetWebUpdateDeployment().InstallReasonKey
                ?? ApiMessageKeys.CoreUpdateUnsupported);
        }
        if (GetWebUpdateRuntimeInstallReason() is { } runtimeReason)
            return OperationView.Fail("web_update_runtime_unavailable", runtimeReason);
        if (Config.CheckUpdateItem.SelectedCoreTypes is { } selected
            && !selected.Contains(WebUpdateTarget, StringComparer.Ordinal))
        {
            return OperationView.Fail("web_update_not_selected", ApiMessageKeys.CoreUpdateUnsupported);
        }

        if (!_moduleUpdates.TryStart("web-update", () => { }, () => RunWebUpdateAsync(
                GetUpdatePreRelease(WebUpdateTarget, preRelease), useProxy ?? Config.CheckUpdateItem.UpdateViaProxy)))
            return OperationView.Fail("core_update_busy", ApiMessageKeys.CoreUpdateBusy);
        return OperationView.Ok(ApiMessageKeys.CoreUpdateStarted, new { target = WebUpdateTarget });
    }

    internal CoreUpdateProgressView? GetWebUpdateProgress()
    {
        var inMemory = _updateProgress.GetValueOrDefault(WebUpdateTarget);
        if (inMemory is { IsComplete: false } || inMemory?.Phase == "completed") return inMemory;
        try
        {
            var path = Utils.GetTempPath(WebUpdateProgressFile);
            if (!File.Exists(path)) return inMemory;
            var persisted = JsonSerializer.Deserialize<WebUpdateProgressState>(File.ReadAllText(path), JsonOptions);
            if (persisted is null) return inMemory;
            var progress = new CoreUpdateProgressView(
                WebUpdateTarget,
                persisted.Phase,
                persisted.IsComplete,
                persisted.Success,
                persisted.CoreWasRunning,
                persisted.Version,
                persisted.Detail,
                false,
                persisted.RollbackSucceeded);
            // In-flight persisted progress belongs to the detached helper. Caching
            // it as local progress would prevent subsequent reads of its result.
            if (progress.IsComplete) _updateProgress[WebUpdateTarget] = progress;
            return progress;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            AddLog("update", $"Could not read the native Web update progress: {exception.Message}");
            return inMemory;
        }
    }

    private Task RunWebUpdateAsync(bool preRelease, bool useProxy) =>
        new ApplicationUpdateService(new ApplicationUpdateAdapter(this, preRelease, useProxy)).RunAsync();

    private async Task<WebUpdateReleaseCheck> CheckWebUpdateReleaseAsync(
        bool allowPrerelease,
        bool useProxy,
        CancellationToken cancellationToken)
    {
        try
        {
            var repository = WebBuildIdentity.Current.Repository;
            var downloader = new DownloadService();
            var releaseJson = await downloader.TryDownloadString(
                WebReleaseChannel.BuildReleaseIndexUrl(repository),
                useProxy,
                $"v2rayN.WebAPI/{WebBuildIdentity.Current.Version}",
                cancellationToken);
            if (string.IsNullOrWhiteSpace(releaseJson) || releaseJson.Length > 8 * 1024 * 1024)
                return WebUpdateReleaseCheck.Failed("The GitHub Web release index could not be downloaded or exceeded its size limit.");

            var candidates = ParseWebReleaseCandidates(releaseJson, allowPrerelease);
            if (candidates.Count == 0)
                return WebUpdateReleaseCheck.Failed("No v2rayN releases with Web update packages were found for this channel.");
            candidates.Sort((left, right) => new ServiceLib.Models.Dto.SemanticVersion(right.Version)
                .CompareTo(new ServiceLib.Models.Dto.SemanticVersion(left.Version)));
            var selected = candidates[0];
            if (!WebReleaseChannel.IsTrustedAssetUrl(selected.ManifestUrl, repository, selected.Tag, WebReleaseChannel.ManifestAssetName))
                return WebUpdateReleaseCheck.Failed("The Web release manifest URL did not match the trusted release channel.");

            var manifestJson = await downloader.TryDownloadString(
                selected.ManifestUrl,
                useProxy,
                $"v2rayN.WebAPI/{WebBuildIdentity.Current.Version}",
                cancellationToken);
            if (string.IsNullOrWhiteSpace(manifestJson) || manifestJson.Length > 1024 * 1024)
                return WebUpdateReleaseCheck.Failed("The Web release manifest could not be downloaded or exceeded its size limit.");
            var manifest = WebUpdatePackageStager.ParseManifest(manifestJson);
            if (manifest.Version != selected.Version)
                return WebUpdateReleaseCheck.Failed("The Web release manifest version does not match its release tag.");

            var currentRid = WebBuildIdentity.Current.Rid;
            var package = manifest.Packages.FirstOrDefault(item => item.Rid == currentRid);
            if (package is null)
            {
                return new WebUpdateReleaseCheck(false, manifest.Version, manifest.Commit, manifest, null,
                    "This v2rayN.WebAPI release does not include a package for the current runtime identifier.",
                    "No package matches runtime " + currentRid + ".");
            }
            var expectedAsset = WebUpdatePackageStager.AppOnlyAssetName(package.Rid);
            if (string.IsNullOrEmpty(expectedAsset)
                || package.Asset != expectedAsset
                || !selected.Assets.TryGetValue(package.Asset, out var releaseAsset)
                || releaseAsset.Url != package.Url
                || releaseAsset.Size != package.Size
                || !WebReleaseChannel.IsTrustedAssetUrl(package.Url, repository, selected.Tag, package.Asset))
            {
                return WebUpdateReleaseCheck.Failed("The Web package entry does not match a trusted asset attached to this release.");
            }

            var currentVersion = WebBuildIdentity.Current.Version;
            var updateAvailable = WebUpdatePackageStager.IsUpdateAvailable(
                currentVersion, manifest.Version, allowPrerelease, WebBuildIdentity.Current.Commit, manifest.Commit);
            var detail = updateAvailable
                ? "A newer v2rayN.WebAPI release is available."
                : new ServiceLib.Models.Dto.SemanticVersion(currentVersion)
                    .CompareTo(new ServiceLib.Models.Dto.SemanticVersion(manifest.Version)) > 0
                    ? "This Web build is newer than the latest release in the selected channel."
                    : "The v2rayN.WebAPI build is up to date.";
            return new WebUpdateReleaseCheck(updateAvailable, manifest.Version, manifest.Commit, manifest, package, null, detail);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or JsonException or InvalidDataException or ArgumentException)
        {
            return WebUpdateReleaseCheck.Failed(exception.Message);
        }
    }

    /// <summary>
    /// Extracts official release candidates that carry a Web update manifest from a GitHub
    /// "list releases" response. Legacy <c>web-v*</c> tags are intentionally ignored.
    /// </summary>
    internal static List<WebReleaseCandidate> ParseWebReleaseCandidates(string releaseJson, bool allowPrerelease)
    {
        using var document = JsonDocument.Parse(releaseJson);
        if (document.RootElement.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("The GitHub Web release index has an invalid format.");

        var candidates = new List<WebReleaseCandidate>();
        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (release.TryGetProperty("draft", out var draft) && draft.GetBoolean()) continue;
            var isPrerelease = release.TryGetProperty("prerelease", out var prerelease) && prerelease.GetBoolean();
            if (!WebUpdatePackageStager.ShouldConsiderRelease(isPrerelease, allowPrerelease)) continue;
            var tag = release.TryGetProperty("tag_name", out var tagElement) ? tagElement.GetString() : null;
            if (!WebReleaseChannel.TryParseReleaseTag(tag, out var version)) continue;
            var assets = new Dictionary<string, (string Url, long Size)>(StringComparer.Ordinal);
            if (release.TryGetProperty("assets", out var assetsElement) && assetsElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var asset in assetsElement.EnumerateArray())
                {
                    var name = asset.TryGetProperty("name", out var nameElement) ? nameElement.GetString() : null;
                    var url = asset.TryGetProperty("browser_download_url", out var urlElement) ? urlElement.GetString() : null;
                    var size = asset.TryGetProperty("size", out var sizeElement) && sizeElement.TryGetInt64(out var parsedSize)
                        ? parsedSize : 0;
                    if (!string.IsNullOrWhiteSpace(name) && !string.IsNullOrWhiteSpace(url)) assets[name] = (url, size);
                }
            }
            if (assets.TryGetValue(WebReleaseChannel.ManifestAssetName, out var manifestAsset))
                candidates.Add(new WebReleaseCandidate(tag!, version, isPrerelease, manifestAsset.Url, assets));
        }
        return candidates;
    }

    private Task<WebUpdateStage> StageWebUpdateAsync(
        WebUpdateReleaseCheck check, bool useProxy, CancellationToken cancellationToken, bool batch) =>
        new ApplicationPackageStagingService<WebUpdateStage>(new ApplicationPackageStaging(this, check, useProxy, batch))
            .StageAsync(cancellationToken);

    private Task ApplyStagedWebUpdateAsync(WebUpdateStage stage, CancellationToken cancellationToken, bool batch) =>
        new ApplicationUpdateHandoffService(new ApplicationUpdateHandoff(this, stage, batch)).ExecuteAsync(cancellationToken);

    private WebUpdateDeployment GetWebUpdateDeployment()
    {
        var isContainer = File.Exists("/.dockerenv") || File.Exists("/run/.containerenv")
            || !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("container"))
            || !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("DOTNET_RUNNING_IN_CONTAINER"));
        var isSystemd = LauncherEnvironment.IsSystemdManagedDeployment();
        var executable = Environment.ProcessPath;
        var expectedExecutableName = WebUpdatePackageStager.IsSupportedRid(WebBuildIdentity.Current.Rid)
            ? WebUpdatePackageStager.ExecutableNameForRid(WebBuildIdentity.Current.Rid)
            : null;
        var pathComparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var nativeSingleFile = expectedExecutableName is not null && !string.IsNullOrWhiteSpace(executable)
            && Path.GetFileName(executable).Equals(expectedExecutableName, pathComparison)
            && File.Exists(executable)
            && string.Equals(AppContext.BaseDirectory,
                Path.GetDirectoryName(Path.GetFullPath(executable)) + Path.DirectorySeparatorChar,
                pathComparison);
        var installDirectory = nativeSingleFile && executable is not null ? Path.GetDirectoryName(executable)! : string.Empty;
        var writable = nativeSingleFile && !isSystemd && IsWritableInstallDirectory(installDirectory, executable!);
        var supportedNativePlatform = OperatingSystem.IsLinux() || OperatingSystem.IsWindows();
        return WebUpdateDeploymentPolicy.Evaluate(supportedNativePlatform, isContainer, isSystemd, nativeSingleFile, writable);
    }

    private bool CanInstallWebUpdate() =>
        WebUpdatePackageStager.IsSupportedRid(WebBuildIdentity.Current.Rid)
        && GetWebUpdateDeployment().CanInstall
        && GetWebUpdateRuntimeInstallReason() is null;

    internal string? GetWebUpdateRuntimeInstallReason()
    {
        if (!WebProbeUriResolver.TryResolve(_configuration, out _))
        {
            // The update helper verifies both the replacement and its rollback through
            // the loopback health endpoint; an unprobeable listener would strand the
            // service, so installing is refused before anything is stopped.
            return "maintenance.webUpdateProbeUnavailable";
        }

        var snapshot = CurrentCoreRuntime;
        var activeChild = HasTrackedCoreProcesses;
        if (snapshot.State is CoreRuntimeState.Starting or CoreRuntimeState.Stopping or CoreRuntimeState.Restarting)
            return ApiMessageKeys.CoreRuntimeBusy;
        if (snapshot.State == CoreRuntimeState.Faulted && activeChild)
            return "maintenance.webUpdateRuntimeFaulted";
        if (snapshot.State == CoreRuntimeState.Running && !activeChild
            || snapshot.State == CoreRuntimeState.Stopped && activeChild)
            return "maintenance.webUpdateRuntimeFaulted";
        return null;
    }

    private static bool IsWritableInstallDirectory(string installDirectory, string executablePath)
    {
        try
        {
            if (new DirectoryInfo(installDirectory).LinkTarget is not null
                || new FileInfo(executablePath).LinkTarget is not null)
                return false;
            var probe = Path.Combine(installDirectory, $".v2rayn-WebAPI-write-probe-{Guid.NewGuid():N}");
            using (new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
            File.Delete(probe);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    private string GetWebUpdateInstallReasonKey() => GetWebUpdateDeployment().InstallReasonKey
        ?? GetWebUpdateRuntimeInstallReason()
        ?? "maintenance.webUpdateUnsupported";

    private static string ToDeploymentName(WebDeploymentKind kind) => kind switch
    {
        WebDeploymentKind.NativeWritable => "native-writable",
        WebDeploymentKind.SystemdManaged => "systemd-managed",
        WebDeploymentKind.Container => "container",
        WebDeploymentKind.ReadOnly => "native-read-only",
        _ => "unsupported",
    };

    private static async Task WriteNativeWebUpdatePlanAsync(string planPath, NativeWebUpdatePlan plan)
    {
        var temporary = planPath + $".{Guid.NewGuid():N}.tmp";
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(plan, JsonOptions));
        File.Move(temporary, planPath);
        if (OperatingSystem.IsLinux())
        {
            File.SetUnixFileMode(planPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    private static string[] GetCurrentHostArguments()
    {
        var args = Environment.GetCommandLineArgs().Skip(1).ToArray();
        return WebLaunchOptions.Parse(
            args,
            OperatingSystem.IsLinux(),
            daemonEnvironment: false,
            containerEnvironment: false,
            interactiveLaunch: false).HostArguments;
    }

    private static void CopyVerifiedWebApp(string source, string destination, string rid)
    {
        Directory.CreateDirectory(destination);
        var executableName = WebUpdatePackageStager.ExecutableNameForRid(rid);
        File.Copy(Path.Combine(source, executableName), Path.Combine(destination, executableName));
        File.Copy(Path.Combine(source, "v2rayN.WebAPI.build.json"), Path.Combine(destination, "v2rayN.WebAPI.build.json"));
        if (OperatingSystem.IsLinux() && rid.StartsWith("linux-", StringComparison.Ordinal))
        {
            File.SetUnixFileMode(Path.Combine(destination, executableName),
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
                | UnixFileMode.GroupRead | UnixFileMode.GroupExecute
                | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
        }
    }

    private static void CleanupWebUpdateStage(WebUpdateStage? stage)
    {
        if (stage is null) return;
        CleanupWebUpdateStageFiles(stage.ArchivePath, stage.PackageDirectory,
            stage.TransferredToHelper ? null : stage.CandidateDirectory);
    }

    private static void CleanupWebUpdateStageFiles(string archive, string packageDirectory, string? candidateDirectory)
    {
        TryDeleteFile(archive);
        TryDeleteDirectory(packageDirectory);
        if (candidateDirectory is not null) TryDeleteDirectory(candidateDirectory);
    }

    private void PublishWebUpdateProgress(
        string phase,
        bool complete,
        bool success,
        string? detail,
        string? version = null,
        bool batch = false)
    {
        var progress = new CoreUpdateProgressView(WebUpdateTarget, phase, complete, success,
            HasTrackedCoreProcesses, version, detail, batch);
        _updateProgress[WebUpdateTarget] = progress;
        _events.Publish("core-update-progress", progress);
        AddLog("update", $"v2rayN.WebAPI update phase: {phase}");
        try
        {
            var path = Utils.GetTempPath(WebUpdateProgressFile);
            var temporary = path + $".{Guid.NewGuid():N}.tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(progress, JsonOptions));
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            AddLog("update", $"Could not persist Web update progress: {exception.Message}");
        }
    }

    private static void TryDeleteFile(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private static void TryDeleteDirectory(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    internal sealed record WebUpdateReleaseCheck(
        bool IsUpdateAvailable,
        string? Version,
        string? Commit,
        WebUpdateManifest? Manifest,
        WebUpdatePackage? Package,
        string? Error,
        string? Detail)
    {
        public static WebUpdateReleaseCheck Failed(string detail) => new(false, null, null, null, null, detail, detail);
    }

    internal sealed record WebUpdateStage(
        string ArchivePath,
        string PackageDirectory,
        string CandidateDirectory,
        string BackupDirectory,
        string InstallDirectory,
        WebUpdateManifest Manifest,
        WebUpdatePackage Package) : IApplicationUpdateArtifact
    {
        public string Version => Manifest.Version;
        public bool TransferredToHelper { get; set; }
    }

    internal sealed record WebReleaseCandidate(
        string Tag,
        string Version,
        bool IsPrerelease,
        string ManifestUrl,
        IReadOnlyDictionary<string, (string Url, long Size)> Assets);
}
