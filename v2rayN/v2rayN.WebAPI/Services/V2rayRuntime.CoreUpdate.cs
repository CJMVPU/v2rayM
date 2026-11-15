using V2rayM.Application.Updates;
using v2rayN.WebAPI.Adapters.Settings;
using V2rayM.Domain.Updates;
using V2rayM.Domain.Runtime;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.CoreConfigs;
using ServiceLib.Models.Dto;
using ServiceLib.Models.Entities;
using ServiceLib.Resx;
using ServiceLib.Services;
using v2rayN.WebAPI.Contracts;
using v2rayN.WebAPI.MacOS;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private const string GeoFilesUpdateTarget = UpdatePreferencePolicy.GeoTarget;
    private const string WebUpdateTarget = "v2rayN.WebAPI";
    internal static string NormalizeWebUpdateTarget(string target) => target == "v2rayN.Web" ? WebUpdateTarget : target;

    internal static List<string>? NormalizeWebUpdateTargets(IEnumerable<string>? targets) =>
        targets?.Select(NormalizeWebUpdateTarget).Distinct(StringComparer.Ordinal).ToList();
    private readonly GeoFilesUpdateGate _geoUpdateGate = new();
    private ConcurrentDictionary<string, CoreUpdateProgressView> _updateProgress => _moduleUpdates.Progress;

    internal bool GetUpdatePreRelease(string target, bool? preRelease = null) =>
        (OperatingSystem.IsMacOS() && target == "Xray") || (preRelease ?? (Config.CheckUpdateItem.CheckPreReleaseCoreTypes?.Contains(target, StringComparer.Ordinal) ?? false));

    public CoreUpdateSettingsView GetCoreUpdateSettings()
    {
        var manager = CoreInfoManager.Instance;
        var selectedTypes = Config.CheckUpdateItem.SelectedCoreTypes;
        var targets = GetAvailableWebCoreUpdateTypes()
            .Select(coreType =>
            {
                var isSupported = manager.IsCheckUpdateSupported(coreType)
                    && manager.GetCoreInfo(coreType) is { } info
                    && IsCurrentPlatformDownloadSupported(info);
                var canInstall = isSupported
                    && coreType != ECoreType.v2rayN
                    && CoreUpdatePackageStager.SupportsCore(coreType);
                var unsupportedReason = coreType == ECoreType.v2rayN
                    ? "maintenance.webUpdateUnsupported"
                    : canInstall ? null : "maintenance.updateUnsupported";
                var storageName = coreType.ToString();
                return new CoreUpdateTargetView(
                    storageName,
                    GetCoreUpdateNameKey(coreType),
                    isSupported,
                    canInstall,
                    manager.GetCheckPreRelease(coreType, preRelease: true),
                    selectedTypes?.Contains(storageName, StringComparer.Ordinal) ?? true,
                    unsupportedReason);
            })
            .ToArray();

        var preReleaseNames = GetAvailablePreReleaseUpdateTargets();
        return new CoreUpdateSettingsView(
            targets,
            selectedTypes?.Contains(GeoFilesUpdateTarget, StringComparer.Ordinal) ?? true,
            GetUpdatePreRelease(WebUpdateTarget),
            Config.CheckUpdateItem.UpdateViaProxy,
            Config.CheckUpdateItem.CheckPreReleaseCoreTypes?
                .Where(preReleaseNames.Contains)
                .Distinct(StringComparer.Ordinal)
                .ToArray() ?? []);
    }

    public IReadOnlyList<CoreUpdateProgressView> GetCoreUpdateProgress() =>
        _updateProgress.Values
            .Append(GetWebUpdateProgress())
            .Where(item => item is not null)
            .Select(item => item!)
            .GroupBy(item => item.CoreType, StringComparer.Ordinal)
            .Select(group => group.Last())
            .OrderBy(item => item.CoreType, StringComparer.Ordinal)
            .ToArray();

    public async Task<OperationView> SaveCoreUpdateSettingsAsync(CoreUpdateSettingsInput input)
    {
        var policy = new UpdatePreferencePolicy(GetAvailableWebCoreUpdateTypes()
            .Select(type => type.ToString()).Append(WebUpdateTarget), GetAvailablePreReleaseUpdateTargets());
        var result = await new UpdatePreferenceService(new ServiceLibUpdatePreferences(_configStore), _mutations, policy)
            .SaveAsync(new(NormalizeWebUpdateTargets(input.SelectedCoreTypes), NormalizeWebUpdateTargets(input.CheckPreReleaseCoreTypes), input.PreRelease, input.UseProxy));
        return result.Status switch
        {
            UpdatePreferenceStatus.Saved => OperationView.Ok(ApiMessageKeys.CoreUpdateSettingsSaved),
            UpdatePreferenceStatus.Invalid => OperationView.Fail("core_update_settings_invalid", ApiMessageKeys.CommonInvalidInput),
            _ => OperationView.Fail("core_update_settings_save_failed", ApiMessageKeys.CommonInternal, new
            {
                stage = "config_save", detail = result.Detail, configRestored = result.Restored, rollbackDetail = result.RollbackDetail,
            }),
        };
    }

    public async Task<ApiEnvelope<CoreUpdateCheckView>> CheckCoreUpdateAsync(
        ECoreType coreType,
        bool? preRelease,
        bool? useProxy,
        CancellationToken cancellationToken)
    {
        if (!CanCheckCoreUpdate(coreType))
        {
            return ApiEnvelope<CoreUpdateCheckView>.Fail(
                "core_update_unsupported",
                ApiMessageKeys.CoreUpdateUnsupported);
        }

        var checkedUpdate = await CheckCoreUpdateResultAsync(coreType, preRelease, useProxy, cancellationToken);
        var result = checkedUpdate.Result;
        if (checkedUpdate.AwaitingValidation)
        {
            return ApiEnvelope<CoreUpdateCheckView>.Ok(
                new CoreUpdateCheckView(true, result.VersionLabel, Detail: result.Msg, AwaitingCompatibilityValidation: true),
                ApiMessageKeys.CoreUpdateAvailable);
        }
        if (checkedUpdate.CanStage)
        {
            return ApiEnvelope<CoreUpdateCheckView>.Ok(
                new CoreUpdateCheckView(true, result.VersionLabel),
                ApiMessageKeys.CoreUpdateAvailable);
        }
        if (checkedUpdate.IsUpToDate)
        {
            return ApiEnvelope<CoreUpdateCheckView>.Ok(
                new CoreUpdateCheckView(false, result.VersionLabel, IsUpToDate: true, Detail: result.Msg),
                ApiMessageKeys.CoreUpdateCurrent);
        }

        AddLog("update", $"{coreType} update check failed: {result.Msg}");
        return ApiEnvelope<CoreUpdateCheckView>.Fail(
            "core_update_check_failed",
            ApiMessageKeys.CoreUpdateCheckFailed,
            new CoreUpdateCheckView(false, null, Detail: result.Msg));
    }

    public Task<ApiEnvelope<CoreUpdateCheckView>> CheckXrayUpdateAsync(
        bool preRelease,
        bool useProxy,
        CancellationToken cancellationToken) =>
        CheckCoreUpdateAsync(ECoreType.Xray, preRelease, useProxy, cancellationToken);

    public OperationView StartCoreUpdate(ECoreType coreType, bool? preRelease = null, bool? useProxy = null)
    {
        if (!CanInstallCoreUpdate(coreType))
        {
            return OperationView.Fail("core_update_unsupported", ApiMessageKeys.CoreUpdateUnsupported);
        }

        var selected = Config.CheckUpdateItem.SelectedCoreTypes;
        if (selected is not null && !selected.Contains(coreType.ToString(), StringComparer.Ordinal))
            return OperationView.Fail("core_update_not_selected", ApiMessageKeys.CoreUpdateUnsupported);
        if (!_moduleUpdates.TryStart(GetCoreUpdateOperationName(coreType),
            () => PublishCoreUpdateProgress(coreType, "queued", false, false, IsCoreTypeRunning(coreType), null, null),
            () => RunCoreUpdateAsync(coreType, GetUpdatePreRelease(coreType.ToString(), preRelease),
                useProxy ?? Config.CheckUpdateItem.UpdateViaProxy)))
            return OperationView.Fail("core_update_busy", ApiMessageKeys.CoreUpdateBusy);

        return OperationView.Ok(ApiMessageKeys.CoreUpdateStarted, new { coreType = coreType.ToString() });
    }

    public bool StartXrayUpdate(bool preRelease, bool useProxy) =>
        StartCoreUpdate(ECoreType.Xray, preRelease, useProxy).Success;

    public OperationView StartSelectedCoreUpdateBatch(bool apply)
    {
        var selected = Config.CheckUpdateItem.SelectedCoreTypes;
        var webSupported = WebUpdatePackageStager.IsSupportedRid(WebBuildIdentity.Current.Rid);
        var selectedNames = selected is null
            ? GetAvailableWebCoreUpdateTypes().Select(coreType => coreType.ToString())
                .Append(GeoFilesUpdateTarget)
                .Concat(webSupported ? [WebUpdateTarget] : [])
                .ToArray()
            : selected.ToArray();
        var targets = GetAvailableWebCoreUpdateTypes()
            .Where(coreType => selectedNames.Contains(coreType.ToString(), StringComparer.Ordinal))
            .ToArray();
        var includeGeoFiles = selectedNames.Contains(GeoFilesUpdateTarget, StringComparer.Ordinal);
        var includeWeb = webSupported && selectedNames.Contains(WebUpdateTarget, StringComparer.Ordinal);
        if (targets.Length == 0 && !includeGeoFiles && !includeWeb)
        {
            return OperationView.Fail("core_update_batch_empty", ApiMessageKeys.CommonInvalidInput);
        }

        if (!_moduleUpdates.TryStart("core-update-batch", () =>
            {
                foreach (var target in targets)
                    PublishCoreUpdateProgress(target, "queued", false, false, IsCoreTypeRunning(target), null, null, batch: true);
                if (includeGeoFiles) PublishGeoUpdateProgress("queued", false, false, null, batch: true);
            }, () => RunSelectedCoreUpdateBatchAsync(targets, includeGeoFiles, includeWeb, apply,
                Config.CheckUpdateItem.UpdateViaProxy)))
            return OperationView.Fail("core_update_busy", ApiMessageKeys.CoreUpdateBusy);

        var targetNames = targets.Select(coreType => coreType.ToString()).ToList();
        if (includeGeoFiles) targetNames.Add(GeoFilesUpdateTarget);
        if (includeWeb) targetNames.Add(WebUpdateTarget);
        return OperationView.Ok(ApiMessageKeys.CoreUpdateBatchStarted, new { apply, targets = targetNames });
    }

    public OperationView StartGeoUpdate(bool? useProxy = null, string scope = "all")
    {
        if (!GeoUpdateSelection.IsValid(scope)) return OperationView.Fail("geo_update_scope_invalid", ApiMessageKeys.CommonInvalidInput);
        var selected = Config.CheckUpdateItem.SelectedCoreTypes;
        if (selected is not null && !selected.Contains(GeoFilesUpdateTarget, StringComparer.Ordinal))
        {
            return OperationView.Fail("geo_update_not_selected", ApiMessageKeys.GeoUpdateNotSelected);
        }

        var proxy = useProxy ?? Config.CheckUpdateItem.UpdateViaProxy;
        if (!_moduleUpdates.TryStart("geo-update", () => PublishGeoUpdateProgress("queued", false, false, null),
                () => RunGeoUpdateAsync(proxy, scope)))
            return OperationView.Fail("geo_update_busy", ApiMessageKeys.GeoUpdateBusy);
        return OperationView.Ok(ApiMessageKeys.GeoUpdateStarted);
    }

    internal IReadOnlyList<string> GetRunningCoreUpdateOperations() => _moduleUpdates.RunningOperations();

    private Task RunSelectedCoreUpdateBatchAsync(
        IReadOnlyList<ECoreType> coreTypes, bool includeGeoFiles, bool includeWeb, bool apply, bool useProxy)
    {
        var targets = coreTypes.Select(core => new BatchUpdateTarget(core.ToString(), BatchTargetKind.Core)).ToList();
        if (includeGeoFiles) targets.Add(new(GeoFilesUpdateTarget, BatchTargetKind.GeoFiles));
        if (includeWeb) targets.Add(new(WebUpdateTarget, BatchTargetKind.Application));
        return new UpdateBatchService(new UpdateBatchAdapter(this, useProxy)).RunAsync(targets, apply);
    }

    private HashSet<string> GetAvailablePreReleaseUpdateTargets() =>
        GetAvailableWebCoreUpdateTypes()
            .Where(coreType => CoreInfoManager.Instance.GetCheckPreRelease(coreType, true))
            .Select(coreType => coreType.ToString())
            .Append(WebUpdateTarget)
            .ToHashSet(StringComparer.Ordinal);

    private IReadOnlyList<ECoreType> GetAvailableWebCoreUpdateTypes()
    {
        var manager = CoreInfoManager.Instance;
        return manager.GetCheckUpdateCoreTypes()
            .Where(coreType => coreType != ECoreType.v2rayN
                && manager.IsCheckUpdateSupported(coreType)
                && manager.GetCoreInfo(coreType) is { } coreInfo
                && IsCurrentPlatformDownloadSupported(coreInfo))
            .ToArray();
    }

    private bool CanCheckCoreUpdate(ECoreType coreType)
    {
        var manager = CoreInfoManager.Instance;
        return coreType != ECoreType.v2rayN
            && manager.GetCheckUpdateCoreTypes().Contains(coreType)
            && manager.IsCheckUpdateSupported(coreType)
            && manager.GetCoreInfo(coreType) is { } coreInfo
            && IsCurrentPlatformDownloadSupported(coreInfo);
    }

    private bool CanInstallCoreUpdate(ECoreType coreType) =>
        coreType != ECoreType.v2rayN
        && CanCheckCoreUpdate(coreType)
        && CoreUpdatePackageStager.SupportsCore(coreType);

    private async Task<CoreUpdateCheckResult> CheckCoreUpdateResultAsync(
        ECoreType coreType,
        bool? preRelease,
        bool? useProxy,
        CancellationToken cancellationToken, bool synchronizePrivileged = false)
    {
        var updateService = new UpdateService(Config, (_, _) => Task.CompletedTask);
        var result = await updateService.CheckHasUpdateOnly(
            coreType,
            GetUpdatePreRelease(coreType.ToString(), preRelease),
            useProxy ?? Config.CheckUpdateItem.UpdateViaProxy,
            cancellationToken, synchronizeInstalled: synchronizePrivileged && _macTunLauncher.SupportsTrustedUpdate(coreType));
        var repairDecision = OperatingSystem.IsMacOS() && coreType == ECoreType.Xray
            ? NativeTunCoreCompatibility.ApplyUpdatePolicy(await _installedXrayVersion.ReadIdentityAsync(_xrayPath), result)
            : null;
        return ModuleUpdateCoordinator.Classify(result, repairDecision ?? IsUpToDateResult(coreType, result.Msg));
    }

    private Task RunCoreUpdateAsync(ECoreType coreType, bool preRelease, bool useProxy) =>
        new CoreUpdateRunService().RunAsync(new CoreUpdateRunAdapter(this, coreType, preRelease, useProxy));

    private Task<CoreUpdateStage> DownloadAndVerifyCoreUpdateAsync(ECoreType coreType, UpdateResult check,
        bool useProxy, CancellationToken cancellationToken, bool batch = false) =>
        new CorePackageStagingService().StageAsync(new CorePackageStaging(this, coreType, check, useProxy, batch), cancellationToken);

    private async Task<CoreUpdateApplyResult> ApplyCoreUpdateAsync(CoreUpdateStage stage, CancellationToken cancellationToken, bool batch = false)
    {
        await _coreGate.WaitAsync(cancellationToken);
        try
        {
            // Session construction can reject a path; it must still release this lease.
            var session = new CoreUpdateSession(this, stage, batch);
            return await new CoreUpdateApplyService().ApplyAsync(session, cancellationToken);
        }
        finally { _coreGate.Release(); }
    }

    private async Task<string> VerifyCoreExecutableAsync(
        ECoreType coreType,
        CoreInfo coreInfo,
        string executablePath,
        CancellationToken cancellationToken)
    {
        var versionArgument = coreInfo.VersionArg
            ?? throw new InvalidDataException($"{coreType} has no version-check command configured.");
        var versionOutput = await Utils.GetCliWrapOutput(executablePath, versionArgument, cancellationToken);
        var expectedName = coreInfo.Match ?? coreType.ToString();
        if (!CoreExecutableVersionCheck.IsValid(versionOutput, expectedName))
        {
            throw new InvalidDataException($"The staged {coreType} executable did not pass its version check.");
        }
        if (OperatingSystem.IsMacOS() && coreType == ECoreType.Xray
            && NativeTunCoreCompatibility.HasKnownDarwinBindingBug(versionOutput!))
            throw new InvalidDataException("此 Xray 26.10.21 存在已确认的 macOS TUN 网卡绑定缺陷；保留当前修复版，等待后续内核版本。");
        return versionOutput!.Trim();
    }

    private static string? FindCoreExecutable(CoreInfo coreInfo, string directory) =>
        CoreUpdateFiles.FindCoreExecutable(coreInfo, directory);

    internal static void RemoveSupersededCoreExecutables(CoreInfo info, string candidate, string package) =>
        CoreUpdateFiles.RemoveSupersededCoreExecutables(info, candidate, package);

    private static bool IsCurrentPlatformDownloadSupported(CoreInfo coreInfo)
    {
        var downloadUrl = Utils.IsWindows()
            ? RuntimeInformation.ProcessArchitecture switch
            {
                Architecture.Arm64 => coreInfo.DownloadUrlWinArm64,
                Architecture.X64 => coreInfo.DownloadUrlWin64,
                _ => null,
            }
            : Utils.IsLinux()
                ? RuntimeInformation.ProcessArchitecture switch
                {
                    Architecture.Arm64 => coreInfo.DownloadUrlLinuxArm64,
                    Architecture.RiscV64 => coreInfo.DownloadUrlLinuxRiscV64,
                    Architecture.LoongArch64 => coreInfo.DownloadUrlLinuxLoong64,
                    Architecture.X64 => coreInfo.DownloadUrlLinux64,
                    _ => null,
                }
                : Utils.IsMacOS()
                    ? RuntimeInformation.ProcessArchitecture switch
                    {
                        Architecture.Arm64 => coreInfo.DownloadUrlOSXArm64,
                        Architecture.X64 => coreInfo.DownloadUrlOSX64,
                        _ => null,
                    }
                    : null;

        return !string.IsNullOrWhiteSpace(downloadUrl);
    }

    internal static bool IsUpToDateResult(ECoreType coreType, string? message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return false;
        }

        const string typeMarker = "__V2RAYN_CORE_TYPE__";
        const string versionMarker = "__V2RAYN_CORE_VERSION__";
        var template = string.Format(ResUI.IsLatestCore, typeMarker, versionMarker);
        var typePosition = template.IndexOf(typeMarker, StringComparison.Ordinal);
        var versionPosition = template.IndexOf(versionMarker, StringComparison.Ordinal);
        if (typePosition < 0 || versionPosition <= typePosition)
        {
            return false;
        }

        var expectedPrefix = template[..typePosition]
            + coreType
            + template[(typePosition + typeMarker.Length)..versionPosition];
        var suffix = template[(versionPosition + versionMarker.Length)..];
        var normalizedMessage = message.Trim();
        if (!normalizedMessage.StartsWith(expectedPrefix, StringComparison.OrdinalIgnoreCase)
            || !normalizedMessage.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var versionLength = normalizedMessage.Length - expectedPrefix.Length - suffix.Length;
        return versionLength > 0
            && normalizedMessage.Substring(expectedPrefix.Length, versionLength).All(character => !char.IsWhiteSpace(character));
    }

    private bool IsCoreTypeRunning(ECoreType coreType) =>
        CoreUpdatePolicy.IsTargetRunning(CurrentCoreRuntime.State, CurrentCoreRuntime.CoreType == coreType, HasTrackedCoreProcesses);

    private static string GetArchiveSuffix(string downloadUrl)
    {
        var path = Uri.TryCreate(downloadUrl, UriKind.Absolute, out var uri) ? uri.AbsolutePath : downloadUrl;
        return path.EndsWith(".tar.gz", StringComparison.OrdinalIgnoreCase)
            ? ".tar.gz"
            : Path.GetExtension(path);
    }

    private static void CopyCoreDirectory(string sourceDirectory, string destinationDirectory) =>
        CoreUpdateFiles.CopyCoreDirectory(sourceDirectory, destinationDirectory);

    private void CleanupCoreUpdateStage(CoreUpdateStage? stage)
    {
        if (stage is not null)
        {
            CleanupCoreUpdateStageFiles(stage.ArchivePath, stage.PackagePath);
        }
    }

    private void CleanupCoreUpdateStageFiles(string archivePath, string packagePath)
    {
        try
        {
            if (Directory.Exists(packagePath))
            {
                Directory.Delete(packagePath, recursive: true);
            }
        }
        catch (Exception exception)
        {
            AddLog("update", $"Core package staging cleanup failed: {exception.Message}");
        }
        try
        {
            if (File.Exists(archivePath))
            {
                File.Delete(archivePath);
            }
        }
        catch (Exception exception)
        {
            AddLog("update", $"Core archive cleanup failed: {exception.Message}");
        }
    }

    private Task RunGeoUpdateAsync(bool useProxy, string scope) =>
        new V2rayM.Application.Updates.GeoUpdateRunService().RunAsync(new GeoUpdateRunAdapter(this, useProxy, scope));

    private async Task ApplyGeoFilesUpdateAsync(
        bool useProxy,
        CancellationToken cancellationToken,
        bool publishProgress = true,
        Func<Func<Task>, CancellationToken, Task>? beforeCommit = null,
        bool batch = false, string scope = "all")
    {
        // The native client uses Xray DAT rules.
        if (OperatingSystem.IsMacOS() && scope == "all") scope = "geo";
        await _geoUpdateGate.RunAsync(async () =>
        {
            var completion = new GeoFilesUpdateCompletion();
            var progressLogClock = System.Diagnostics.Stopwatch.StartNew();
            var progressLogged = false;
            var updater = new UpdateService(Config, (success, message) =>
            {
                var isProgress = IsGeoDownloadProgressMessage(message);
                if (!isProgress || !progressLogged || progressLogClock.ElapsedMilliseconds >= 1000)
                {
                    AddLog("update", message);
                    if (isProgress) { progressLogged = true; progressLogClock.Restart(); }
                }
                completion.Report(success, message, isProgress);
                if (publishProgress)
                {
                    _events.Publish("geo-update-progress", new
                    {
                        success,
                        code = success ? "ok" : "geo_update_progress",
                        messageKey = success ? ApiMessageKeys.CommonCompleted : ApiMessageKeys.GeoUpdateProgress,
                        rawLog = message,
                    });
                }
                return Task.CompletedTask;
            }) { DownloadProgress = transfer => {
                if (publishProgress) PublishGeoUpdateProgress("downloading", false, false, null, batch, transfer);
            }};

            var managedFiles = GeoUpdateSelection.Filter(await GetManagedGeoFilesAsync(), scope);
            var requiredFiles = scope == "rules" ? managedFiles : GetRequiredGeoFiles();
            await GeoFilesUpdateTransaction.ApplyAsync(
                managedFiles,
                requiredFiles,
                async token =>
                {
                    // Keep download selection, URLs, and installation behavior in the upstream
                    // public API. Its legacy callback reports progress/errors separately from its
                    // final success notification, so reject non-progress failures before commit.
                    await updater.UpdateGeoFileAll(useProxy, token, scope);
                    completion.EnsureSuccessful();
                },
                cancellationToken,
                beforeCommit);
        }, cancellationToken);
    }






    private Task<string[]> GetManagedGeoFilesAsync() => Task.FromResult(GetRequiredGeoFiles());

    private string[] GetRequiredGeoFiles()
    {
        var binDirectory = Utils.GetBinPath(string.Empty);
        var required = new List<string>
        {
            Path.Combine(binDirectory, "geosite.dat"),
            Path.Combine(binDirectory, "geoip.dat"),
        };
        return required.Distinct(StringComparerForPaths).ToArray();
    }

    private static bool IsGeoDownloadProgressMessage(string message)
    {
        var normalized = message.TrimStart();
        return normalized.StartsWith(ResUI.Downloading, StringComparison.OrdinalIgnoreCase)
            || Regex.IsMatch(normalized, @"^\d+/\d+\s*\|", RegexOptions.CultureInvariant);
    }

    private static StringComparer StringComparerForPaths => OperatingSystem.IsWindows()
        ? StringComparer.OrdinalIgnoreCase
        : StringComparer.Ordinal;

    private void PublishCoreUpdateProgress(
        ECoreType coreType,
        string phase,
        bool isComplete,
        bool success,
        bool coreWasRunning,
        string? version,
        string? detail,
        bool batch = false,
        FileTransferProgress? transfer = null)
    {
        var progress = new CoreUpdateProgressView(coreType.ToString(), phase, isComplete, success, coreWasRunning, version, detail, batch,
            DownloadedBytes: transfer?.DownloadedBytes, TotalBytes: transfer?.TotalBytes,
            CompletedFiles: transfer?.CompletedFiles, TotalFiles: transfer?.TotalFiles);
        if (!_updateProgress.TryGetValue(coreType.ToString(), out var previous) || previous.Phase != phase)
        {
            AddLog("update", $"{coreType} update phase: {phase}");
        }
        _updateProgress[coreType.ToString()] = progress;
        _events.Publish("core-update-progress", progress);
        if (coreType == ECoreType.Xray && isComplete && phase != "awaiting-validation")
        {
            _events.Publish("xray-update-completed", success
                ? OperationView.Ok(ApiMessageKeys.XrayUpdateCompleted, new { version, coreRestarted = coreWasRunning })
                : OperationView.Fail("xray_update_failed", ApiMessageKeys.XrayUpdateFailed, new { coreWasRunning, detail }));
        }
    }

    private void PublishGeoUpdateProgress(string phase, bool isComplete, bool success, string? detail, bool batch = false, FileTransferProgress? transfer = null)
    {
        var progress = new CoreUpdateProgressView(GeoFilesUpdateTarget, phase, isComplete, success, false, null, detail, batch,
            DownloadedBytes: transfer?.DownloadedBytes, TotalBytes: transfer?.TotalBytes,
            CompletedFiles: transfer?.CompletedFiles, TotalFiles: transfer?.TotalFiles);
        if (!_updateProgress.TryGetValue(GeoFilesUpdateTarget, out var previous) || previous.Phase != phase)
        {
            AddLog("update", $"GeoFiles update phase: {phase}");
        }
        _updateProgress[GeoFilesUpdateTarget] = progress;
        _events.Publish("core-update-progress", progress);
        if (isComplete)
        {
            _events.Publish("geo-update-completed", success
                ? OperationView.Ok(ApiMessageKeys.CommonCompleted, new { batch })
                : OperationView.Fail("geo_update_failed", ApiMessageKeys.CoreUpdateFailed, new { batch }));
        }
    }

    private async Task DiscardPrivilegedStageAsync(CoreUpdateStage stage)
    {
        try { await _macTunLauncher.TransitionUpdateAsync(stage.CoreType, stage.PrivilegedToken, "update-discard", CancellationToken.None); }
        catch (Exception exception) { AddLog("update", "Privileged staging cleanup deferred: " + exception.Message); }
    }

    private static string GetCoreUpdateOperationName(ECoreType coreType) =>
        $"core-update-{coreType.ToString().ToLowerInvariant()}";

    private static string GetCoreUpdateNameKey(ECoreType coreType) => coreType switch
    {
        ECoreType.Xray => "maintenance.coreNames.xray",
        ECoreType.v2rayN => "maintenance.coreNames.v2rayN",
        _ => "maintenance.coreNames.other",
    };

    internal static void CopyLatestGeoFilesForApply(string installPath, string stagingPath) =>
        CoreUpdateFiles.CopyLatestGeoFilesForApply(installPath, stagingPath);

    internal sealed record CoreUpdateStage(ECoreType CoreType, string InstallPath, string ArchivePath, string PackagePath, string VersionOutput, string? PrivilegedToken = null) : ICoreUpdateArtifact
    { public string Version => VersionOutput; }
}
