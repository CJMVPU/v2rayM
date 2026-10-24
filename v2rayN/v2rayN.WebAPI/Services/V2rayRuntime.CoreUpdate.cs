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
    private const string GeoFilesUpdateTarget = "GeoFiles";
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
        var supportedNames = GetAvailableWebCoreUpdateTypes()
            .Select(type => type.ToString())
            .Append(WebUpdateTarget)
            .ToHashSet(StringComparer.Ordinal);
        var requestedNames = (input.SelectedCoreTypes ?? []).Select(NormalizeWebUpdateTarget)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var preReleaseNames = GetAvailablePreReleaseUpdateTargets();
        // Older clients still submit a single switch. An explicit per-target list takes
        // precedence, including an empty list, and is independent of update selections.
        var requestedPreReleaseNames = NormalizeWebUpdateTargets(input.CheckPreReleaseCoreTypes)?.ToArray()
            ?? (input.PreRelease ? preReleaseNames.ToArray() : []);
        if (requestedNames.Any(name => name != GeoFilesUpdateTarget && !supportedNames.Contains(name))
            || requestedPreReleaseNames.Any(name => !preReleaseNames.Contains(name)))
        {
            return OperationView.Fail("core_update_settings_invalid", ApiMessageKeys.CommonInvalidInput);
        }

        await _mutations.RunAsync(async () =>
        {
            var previous = NormalizeWebUpdateTargets(Config.CheckUpdateItem.SelectedCoreTypes) ?? [];
            // Keep selections from backups that this platform/Web updater cannot display,
            // just as the desktop updater keeps hidden Core configuration untouched.
            var hiddenSelections = previous.Where(name => name != GeoFilesUpdateTarget && !supportedNames.Contains(name));
            Config.CheckUpdateItem.SelectedCoreTypes = hiddenSelections
                .Concat(requestedNames)
                .Distinct(StringComparer.Ordinal)
                .ToList();
            var hiddenPreReleaseSelections = (NormalizeWebUpdateTargets(Config.CheckUpdateItem.CheckPreReleaseCoreTypes) ?? [])
                .Where(name => !preReleaseNames.Contains(name));
            Config.CheckUpdateItem.CheckPreReleaseCoreTypes = hiddenPreReleaseSelections
                .Concat(requestedPreReleaseNames)
                .Distinct(StringComparer.Ordinal)
                .ToList();
            Config.CheckUpdateItem.UpdateViaProxy = input.UseProxy;
            await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
        });

        return OperationView.Ok(ApiMessageKeys.CoreUpdateSettingsSaved);
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

    private async Task RunSelectedCoreUpdateBatchAsync(
        IReadOnlyList<ECoreType> coreTypes,
        bool includeGeoFiles,
        bool includeWeb,
        bool apply,
        bool useProxy)
    {
        var staged = new List<CoreUpdateStage>();
        var overallSuccess = true;
        var reloadGeoRuntime = includeGeoFiles && CurrentCoreRuntime.State == CoreRuntimeState.Running;
        var currentTarget = string.Empty;
        WebUpdateStage? webStage = null;
        try
        {
            // Holding the runtime's exclusive mutation lease prevents a restore or profile
            // mutation from invalidating the checked/staged targets. Read-only status and log
            // requests remain available. No Core process is stopped during this stage.
            await using var maintenance = await _operations.EnterExclusiveAsync(
                _operations.ShutdownToken,
                allowReadOnlyObservations: true);
            var token = maintenance.Token;
            var checks = new List<CoreUpdateBatchCheck>(coreTypes.Count);

            foreach (var coreType in coreTypes)
            {
                currentTarget = coreType.ToString();
                var wasRunning = IsCoreTypeRunning(coreType);
                PublishCoreUpdateProgress(coreType, "checking", false, false, wasRunning, null, null, batch: true);
                var checkedUpdate = await CheckCoreUpdateResultAsync(coreType, null, useProxy, token, synchronizePrivileged: apply);
                var check = checkedUpdate.Result;
                if (checkedUpdate.AwaitingValidation)
                {
                    overallSuccess = false;
                    checks.Add(new CoreUpdateBatchCheck(coreType, checkedUpdate));
                    PublishCoreUpdateProgress(coreType, "awaiting-validation", true, false, wasRunning,
                        check.VersionLabel, check.Msg, batch: true);
                    continue;
                }
                if (checkedUpdate.IsUpToDate)
                {
                    checks.Add(new CoreUpdateBatchCheck(coreType, checkedUpdate));
                    PublishCoreUpdateProgress(coreType, "completed", true, true, wasRunning,
                        check.VersionLabel, check.Msg ?? "Already up to date.", batch: true);
                    continue;
                }

                if (!checkedUpdate.CanStage)
                {
                    overallSuccess = false;
                    PublishCoreUpdateProgress(coreType, "failed", true, false, wasRunning, null, check.Msg, batch: true);
                    AddLog("update", $"Batch update check failed for {coreType}: {check.Msg}");
                    checks.Add(new CoreUpdateBatchCheck(coreType, checkedUpdate));
                    continue;
                }

                checks.Add(new CoreUpdateBatchCheck(coreType, checkedUpdate));
                if (!apply)
                {
                    PublishCoreUpdateProgress(coreType, "completed", true, true, wasRunning,
                        check.VersionLabel, check.Msg ?? "An update is available.", batch: true);
                }
            }

            if (includeGeoFiles)
            {
                PublishGeoUpdateProgress("checking", false, false,
                    "ServiceLib has no read-only GeoFiles check; the transactional GeoFiles update runs only during batch apply.", batch: true);
                if (!apply)
                {
                    PublishGeoUpdateProgress("completed", true, true,
                        "GeoFiles will be downloaded, validated, and applied only when batch apply is enabled.", batch: true);
                }
            }

            WebUpdateReleaseCheck? webCheck = null;
            if (includeWeb)
            {
                currentTarget = WebUpdateTarget;
                PublishWebUpdateProgress("checking", false, false, null, batch: true);
                webCheck = await CheckWebUpdateReleaseAsync(GetUpdatePreRelease(WebUpdateTarget), useProxy, token);
                Volatile.Write(ref _latestWebUpdateVersion, webCheck.Version);
                if (!string.IsNullOrEmpty(webCheck.Error))
                {
                    overallSuccess = false;
                    PublishWebUpdateProgress("failed", true, false, webCheck.Error, webCheck.Version, batch: true);
                }
                else if (!webCheck.IsUpdateAvailable)
                {
                    PublishWebUpdateProgress("completed", true, true, webCheck.Detail ?? "The Web application is up to date.",
                        webCheck.Version, batch: true);
                }
                else if (!apply)
                {
                    var detail = CanInstallWebUpdate()
                        ? "An update is available."
                        : $"An update is available; {GetWebUpdateInstallReasonKey()}";
                    PublishWebUpdateProgress("completed", true, true, detail, webCheck.Version, batch: true);
                }
                else if (!CanInstallWebUpdate())
                {
                    overallSuccess = false;
                    PublishWebUpdateProgress("failed", true, false, GetWebUpdateInstallReasonKey(), webCheck.Version, batch: true);
                }
            }

            if (!apply)
            {
                _events.Publish("core-update-batch-completed", new { success = overallSuccess, apply = false });
                return;
            }

            if (checks.Any(item => item.CheckFailed) || webCheck is { Error: { Length: > 0 } })
            {
                overallSuccess = false;
                foreach (var item in checks.Where(item => !item.CheckFailed && !item.IsUpToDate && !item.AwaitingValidation))
                {
                    PublishCoreUpdateProgress(item.CoreType, "failed", true, false, IsCoreTypeRunning(item.CoreType),
                        item.Check.VersionLabel, "No targets were installed because at least one selected update check failed.", batch: true);
                }
                if (includeGeoFiles)
                {
                    PublishGeoUpdateProgress("failed", true, false, "No updates were installed because a selected update check failed.", batch: true);
                }
                if (webCheck is { Error: { Length: > 0 } })
                {
                    PublishWebUpdateProgress("failed", true, false, "No updates were installed because a selected update check failed.",
                        webCheck.Version, batch: true);
                }
                _events.Publish("core-update-batch-completed", new { success = false, apply = true });
                return;
            }

            var targetsToStage = checks.Where(item => !item.IsUpToDate && !item.AwaitingValidation).ToArray();
            var unsupportedTargets = targetsToStage.Where(item => !CanInstallCoreUpdate(item.CoreType)).ToArray();
            if (unsupportedTargets.Length > 0)
            {
                overallSuccess = false;
                foreach (var item in unsupportedTargets)
                {
                    PublishCoreUpdateProgress(item.CoreType, "failed", true, false, IsCoreTypeRunning(item.CoreType),
                        item.Check.VersionLabel, "This Web deployment can check but cannot safely install this target.", batch: true);
                }
                targetsToStage = targetsToStage.Where(item => CanInstallCoreUpdate(item.CoreType)).ToArray();
            }
            var shouldInstallWeb = includeWeb && webCheck is { IsUpdateAvailable: true } && CanInstallWebUpdate();
            if (targetsToStage.Length == 0 && !includeGeoFiles && !shouldInstallWeb)
            {
                _events.Publish("core-update-batch-completed", new { success = overallSuccess, apply = true });
                return;
            }

            // Complete the GeoFiles transaction while the serving Core remains available.
            // The Web layer snapshots/validates/rolls back files around the upstream updater.
            async Task PrepareAdditionalUpdatesBeforeCoreApplyAsync()
            {
                if (includeGeoFiles)
                {
                    currentTarget = GeoFilesUpdateTarget;
                    PublishGeoUpdateProgress("downloading", false, false, null, batch: true);
                    await ApplyGeoFilesUpdateAsync(useProxy, token, batch: true);
                    PublishGeoUpdateProgress("completed", true, true, null, batch: true);
                }
                if (shouldInstallWeb && webCheck is { } availableWebCheck)
                {
                    currentTarget = WebUpdateTarget;
                    webStage = await StageWebUpdateAsync(availableWebCheck, useProxy, token, batch: true);
                }
            }

            await CoreUpdateWorkflow.StageAllThenApplyAsync(
                targetsToStage,
                async target =>
                {
                    currentTarget = target.CoreType.ToString();
                    var result = await DownloadAndVerifyCoreUpdateAsync(target.CoreType, target.Check, useProxy, token, batch: true);
                    staged.Add(result);
                    return result;
                },
                async completeStage =>
                {
                    // This callback is reached only after every selected package has been
                    // downloaded, extracted, and version-verified successfully.
                    foreach (var stage in completeStage)
                    {
                        PublishCoreUpdateProgress(stage.CoreType, "waiting", false, false,
                            IsCoreTypeRunning(stage.CoreType), stage.VersionOutput, "All selected Core packages are staged and verified.", batch: true);
                    }

                    foreach (var stage in completeStage)
                    {
                        currentTarget = stage.CoreType.ToString();
                        var result = await ApplyCoreUpdateAsync(stage, token, batch: true);
                        overallSuccess &= result.Success;
                        if (result.Success && result.CoreWasRunning) reloadGeoRuntime = false;
                        PublishCoreUpdateProgress(stage.CoreType,
                            result.Success ? "completed" : "failed",
                            isComplete: true,
                            success: result.Success,
                            result.CoreWasRunning,
                            result.Version ?? stage.VersionOutput,
                            result.Detail,
                            batch: true);
                    }
                    return true;
                },
                includeGeoFiles || shouldInstallWeb ? PrepareAdditionalUpdatesBeforeCoreApplyAsync : null);
            if (reloadGeoRuntime && CurrentCoreRuntime.State == CoreRuntimeState.Running)
            {
                PublishGeoUpdateProgress("restarting-core", false, false, null, batch: true);
                var restart = await RestartCoreAsync(token);
                overallSuccess &= restart.Success;
                PublishGeoUpdateProgress(restart.Success ? "completed" : "failed", true, restart.Success,
                    restart.Success ? null : "规则文件已更新，但运行内核未能重新加载，请重新连接。", batch: true);
            }

            if (webStage is not null)
            {
                currentTarget = WebUpdateTarget;
                await ApplyStagedWebUpdateAsync(webStage, token, batch: true);
                // The helper takes over only after every selected Core/Geo package has
                // completed its apply phase; no remaining batch work follows the restart.
                return;
            }

            _events.Publish("core-update-batch-completed", new { success = overallSuccess, apply = true });
        }
        catch (OperationCanceledException) when (_operations.IsStopping)
        {
            overallSuccess = false;
            if (currentTarget == GeoFilesUpdateTarget)
            {
                PublishGeoUpdateProgress("failed", true, false, "Canceled during graceful shutdown.", batch: true);
            }
            else if (currentTarget == WebUpdateTarget)
            {
                PublishWebUpdateProgress("failed", true, false, "Canceled during graceful shutdown.", batch: true);
            }
            else if (Enum.TryParse<ECoreType>(currentTarget, out var coreType))
            {
                PublishCoreUpdateProgress(coreType, "failed", true, false, IsCoreTypeRunning(coreType), null,
                    "Canceled during graceful shutdown.", batch: true);
            }
            _events.Publish("core-update-batch-completed", new { success = false, apply });
        }
        catch (Exception exception)
        {
            overallSuccess = false;
            AddLog("update", $"Core update batch failed at {currentTarget}: {exception}");
            if (Enum.TryParse<ECoreType>(currentTarget, out var coreType))
            {
                PublishCoreUpdateProgress(coreType, "failed", true, false, IsCoreTypeRunning(coreType), null, exception.Message, batch: true);
            }
            else if (currentTarget == GeoFilesUpdateTarget)
            {
                PublishGeoUpdateProgress("failed", true, false, exception.Message, batch: true);
            }
            else if (currentTarget == WebUpdateTarget)
            {
                PublishWebUpdateProgress("failed", true, false, exception.Message, batch: true);
            }
            foreach (var notApplied in staged)
            {
                var progress = _updateProgress.GetValueOrDefault(notApplied.CoreType.ToString());
                if (progress is { IsComplete: false })
                {
                    PublishCoreUpdateProgress(notApplied.CoreType, "failed", true, false,
                        IsCoreTypeRunning(notApplied.CoreType), notApplied.VersionOutput,
                        "The staged package was not applied because another selected target failed.", batch: true);
                }
            }
            _events.Publish("core-update-batch-completed", new { success = false, apply });
        }
        finally
        {
            CleanupWebUpdateStage(webStage);
            foreach (var target in coreTypes) {
                if (_updateProgress.TryGetValue(target.ToString(), out var progress) && !progress.IsComplete)
                    PublishCoreUpdateProgress(target, "failed", true, false, IsCoreTypeRunning(target), progress.Version,
                        "This target was not applied because the batch could not complete.", batch: true);
            }
            if (includeGeoFiles && _updateProgress.TryGetValue(GeoFilesUpdateTarget, out var geoProgress) && !geoProgress.IsComplete)
                PublishGeoUpdateProgress("failed", true, false, "The batch could not complete.", batch: true);
            foreach (var stage in staged) {
                await DiscardPrivilegedStageAsync(stage);
                CleanupCoreUpdateStage(stage);
            }
        }
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

    private async Task RunCoreUpdateAsync(ECoreType coreType, bool preRelease, bool useProxy)
    {
        CoreUpdateStage? stage = null;
        var wasRunning = IsCoreTypeRunning(coreType);
        try
        {
            var result = await CoreUpdateWorkflow.StageThenApplyAsync(
                async () =>
                {
                    await using var operation = await _operations.EnterOperationAsync(_operations.ShutdownToken);
                    PublishCoreUpdateProgress(coreType, "checking", isComplete: false, success: false, wasRunning, null, null);
                    var checkedUpdate = await CheckCoreUpdateResultAsync(coreType, preRelease, useProxy, operation.Token, synchronizePrivileged: true);
                    var check = checkedUpdate.Result;
                    if (checkedUpdate.IsUpToDate || checkedUpdate.AwaitingValidation)
                    {
                        return new CoreUpdatePrepareResult(null, check);
                    }
                    if (!checkedUpdate.CanStage)
                    {
                        throw new InvalidOperationException(check.Msg ?? $"Could not check {coreType} updates.");
                    }

                    stage = await DownloadAndVerifyCoreUpdateAsync(coreType, check, useProxy, operation.Token);
                    return new CoreUpdatePrepareResult(stage, check);
                },
                async prepared =>
                {
                    if (prepared.Stage is null)
                    {
                        return new CoreUpdateApplyResult(!prepared.Check.AwaitingCompatibilityValidation, false, wasRunning,
                            prepared.Check.Msg ?? "Already up to date.", prepared.Check.VersionLabel,
                            AwaitingValidation: prepared.Check.AwaitingCompatibilityValidation);
                    }

                    await using var maintenance = await _operations.EnterExclusiveAsync(
                        _operations.ShutdownToken,
                        allowReadOnlyObservations: true);
                    return await ApplyCoreUpdateAsync(prepared.Stage, maintenance.Token);
                });

            PublishCoreUpdateProgress(
                coreType,
                result.AwaitingValidation ? "awaiting-validation" : "completed",
                isComplete: true,
                success: result.Success,
                result.CoreWasRunning,
                result.Version ?? stage?.VersionOutput,
                result.Detail);
            if (!result.Success && !result.AwaitingValidation)
            {
                AddLog("update", $"{coreType} update failed: {result.Detail}");
            }
        }
        catch (OperationCanceledException) when (_operations.IsStopping)
        {
            PublishCoreUpdateProgress(coreType, "failed", isComplete: true, success: false, wasRunning, stage?.VersionOutput, "Canceled during graceful shutdown.");
        }
        catch (Exception exception)
        {
            AddLog("update", $"{coreType} update failed: {exception.Message}");
            PublishCoreUpdateProgress(coreType, "failed", isComplete: true, success: false, wasRunning, stage?.VersionOutput, exception.Message);
        }
        finally
        {
            if (stage is not null) await DiscardPrivilegedStageAsync(stage);
            CleanupCoreUpdateStage(stage);
        }
    }

    private async Task<CoreUpdateStage> DownloadAndVerifyCoreUpdateAsync(
        ECoreType coreType,
        UpdateResult check,
        bool useProxy,
        CancellationToken cancellationToken,
        bool batch = false)
    {
        var installPath = Path.GetFullPath(Utils.GetBinPath(string.Empty, coreType.ToString()));
        var installParent = Path.GetDirectoryName(installPath)
            ?? throw new InvalidOperationException($"The {coreType} installation path has no parent directory.");
        var archivePath = Utils.GetTempPath($"core-update-{coreType}-{Guid.NewGuid():N}{GetArchiveSuffix(check.Url!)}");
        var packagePath = Path.Combine(installParent, $".{coreType}-package-{Guid.NewGuid():N}");
        Directory.CreateDirectory(packagePath);
        string? privilegedToken = null;

        try
        {
            PublishCoreUpdateProgress(coreType, "downloading", isComplete: false, success: false, IsCoreTypeRunning(coreType), check.VersionLabel, check.Url, batch);
            var download = new DownloadService();
            var downloadFailure = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
            download.Error += (_, args) => downloadFailure.TrySetResult(args.GetException());
            download.ProgressChanged += (_, transfer) =>
                PublishCoreUpdateProgress(coreType, "downloading", false, false, IsCoreTypeRunning(coreType), check.VersionLabel, null, batch, transfer);
            download.UpdateCompleted += (_, progress) =>
            {
                PublishCoreUpdateProgress(coreType, "downloading", isComplete: false, success: false, IsCoreTypeRunning(coreType), check.VersionLabel, progress.Msg, batch);
            };
            await download.DownloadFileAsync(new FileDownloadRequest
            {
                FileUrl = check.Url!,
                FilePath = archivePath,
                DisplayFileName = Path.GetFileName(archivePath),
            },
            useProxy,
            cancellationToken);

            if (downloadFailure.Task.IsCompletedSuccessfully)
            {
                throw new IOException("The core package download failed.", await downloadFailure.Task);
            }
            if (!File.Exists(archivePath))
            {
                throw new IOException("The core package download did not produce an archive.");
            }

            PublishCoreUpdateProgress(coreType, "verifying", isComplete: false, success: false, IsCoreTypeRunning(coreType), check.VersionLabel, null, batch);
            await CoreUpdatePackageStager.ExtractAsync(coreType, archivePath, packagePath, cancellationToken);
            var coreInfo = CoreInfoManager.Instance.GetCoreInfo(coreType)
                ?? throw new InvalidOperationException($"{coreType} version metadata is unavailable.");
            var stagedExecutable = FindCoreExecutable(coreInfo, packagePath)
                ?? throw new InvalidDataException($"The downloaded {coreType} archive does not contain a usable executable.");
            await Utils.SetLinuxChmod(stagedExecutable);
            // A native privileged update authenticates the official package before any
            // executable from that package is run by the unprivileged update workflow.
            if (OperatingSystem.IsMacOS() && coreType is ECoreType.Xray)
            {
                PublishCoreUpdateProgress(coreType, "staging-privileged", false, false, IsCoreTypeRunning(coreType), check.VersionLabel, null, batch);
                privilegedToken = await _macTunLauncher.StageUpdateAsync(coreType, archivePath, check.Url!, cancellationToken);
            }
            var versionOutput = await VerifyCoreExecutableAsync(coreType, coreInfo, stagedExecutable, cancellationToken);
            return new CoreUpdateStage(coreType, installPath, archivePath, packagePath, versionOutput, privilegedToken);
        }
        catch
        {
            if (privilegedToken is not null) {
                try { await _macTunLauncher.TransitionUpdateAsync(coreType, privilegedToken, "update-discard", CancellationToken.None); }
                catch (Exception cleanup) { AddLog("update", "Privileged staging cleanup deferred: " + cleanup.Message); }
            }
            CleanupCoreUpdateStageFiles(archivePath, packagePath);
            throw;
        }
    }

    private async Task<CoreUpdateApplyResult> ApplyCoreUpdateAsync(CoreUpdateStage stage, CancellationToken cancellationToken, bool batch = false)
    {
        await _coreGate.WaitAsync(cancellationToken);
        var installPath = stage.InstallPath;
        var parentDirectory = Path.GetDirectoryName(installPath)
            ?? throw new InvalidOperationException("The Core installation path has no parent directory.");
        var candidatePath = Path.Combine(parentDirectory, $".{stage.CoreType}-candidate-{Guid.NewGuid():N}");
        var backupPath = Path.Combine(parentDirectory, $".{stage.CoreType}-backup-{Guid.NewGuid():N}");
        var hadInstalledCore = Directory.Exists(installPath);
        var originalCoreWasRunning = IsCoreTypeRunning(stage.CoreType)
            || stage.PrivilegedToken is not null && Config.TunModeItem.EnableTun
                && CurrentCoreRuntime.State == CoreRuntimeState.Running && HasTrackedCoreProcesses;
        ProfileItem? runningProfile = null;
        var oldCoreWasStopped = false;
        var candidateInstalled = false;
        var privilegedActivated = false;

        try
        {
            if (originalCoreWasRunning)
            {
                runningProfile = await AppManager.Instance.GetProfileItem(CurrentCoreRuntime.ProfileId ?? string.Empty);
                if (runningProfile is null)
                {
                    return new CoreUpdateApplyResult(false, false, true, "The active profile could not be loaded; the running Core was left unchanged.");
                }
            }

            // Prepare and verify the complete replacement while the serving Core is still
            // alive. This phase performs no network access; proxy-backed downloads and all
            // archive verification have already completed in DownloadAndVerifyCoreUpdateAsync.
            if (hadInstalledCore)
            {
                CopyCoreDirectory(installPath, candidatePath);
            }
            else
            {
                Directory.CreateDirectory(candidatePath);
            }
            foreach (var packageFile in Directory.EnumerateFiles(stage.PackagePath, "*", SearchOption.TopDirectoryOnly))
            {
                cancellationToken.ThrowIfCancellationRequested();
                File.Copy(packageFile, Path.Combine(candidatePath, Path.GetFileName(packageFile)), overwrite: true);
            }
            if (stage.CoreType == ECoreType.Xray)
            {
                CopyLatestGeoFilesForApply(installPath, candidatePath);
            }

            var coreInfo = CoreInfoManager.Instance.GetCoreInfo(stage.CoreType)
                ?? throw new InvalidOperationException($"{stage.CoreType} version metadata is unavailable.");
            RemoveSupersededCoreExecutables(coreInfo, candidatePath, stage.PackagePath);
            var candidateExecutable = FindCoreExecutable(coreInfo, candidatePath)
                ?? throw new InvalidDataException($"The prepared {stage.CoreType} directory has no executable.");
            await Utils.SetLinuxChmod(candidateExecutable);
            await VerifyCoreExecutableAsync(stage.CoreType, coreInfo, candidateExecutable, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

            PublishCoreUpdateProgress(stage.CoreType, "stopping-core", isComplete: false, success: false, originalCoreWasRunning, stage.VersionOutput,
                originalCoreWasRunning ? null : "The updated Core was not running and will remain stopped.", batch);
            if (originalCoreWasRunning)
            {
                SetCoreRuntime(CurrentCoreRuntime with { State = CoreRuntimeState.Stopping, LastFailure = null });
                await StopCoreMonitorAsync();
                await StopCoreAndConfirmAsync(cancellationToken);
                SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
                oldCoreWasStopped = true;
            }

            await _macTunLauncher.TransitionUpdateAsync(stage.CoreType, stage.PrivilegedToken, "update-activate", cancellationToken);
            privilegedActivated = stage.PrivilegedToken is not null;
            PublishCoreUpdateProgress(stage.CoreType, "installing", isComplete: false, success: false, originalCoreWasRunning, stage.VersionOutput, null, batch);
            if (hadInstalledCore)
            {
                Directory.Move(installPath, backupPath);
            }
            try
            {
                Directory.Move(candidatePath, installPath);
                candidateInstalled = true;
            }
            catch
            {
                if (hadInstalledCore && Directory.Exists(backupPath) && !Directory.Exists(installPath))
                {
                    Directory.Move(backupPath, installPath);
                }
                throw;
            }

            await CoreManager.Instance.Init(Config, OnCoreMessageAsync);
            if (stage.CoreType == ECoreType.Xray)
            {
                _xrayPath = FindXrayExecutable(out var missingXrayMessage);
                if (_xrayPath is null)
                {
                    throw new InvalidDataException(missingXrayMessage);
                }
            }

            if (originalCoreWasRunning && runningProfile is not null)
            {
                PublishCoreUpdateProgress(stage.CoreType, "restarting-core", isComplete: false, success: false, true, stage.VersionOutput, null, batch);
                var restart = await StartCoreLockedAsync(runningProfile, cancellationToken);
                if (!restart.Success)
                {
                    throw new InvalidOperationException($"The updated {stage.CoreType} failed to restart ({restart.Code}).");
                }
            }

            await _macTunLauncher.TransitionUpdateAsync(stage.CoreType, stage.PrivilegedToken, "update-finish", cancellationToken);
            privilegedActivated = false;
            if (Directory.Exists(backupPath))
            {
                try
                {
                    Directory.Delete(backupPath, recursive: true);
                }
                catch (Exception exception)
                {
                    AddLog("update", $"{stage.CoreType} updated; previous Core cleanup deferred: {exception.Message}");
                }
            }

            return new CoreUpdateApplyResult(true, false, originalCoreWasRunning, "Update installed and verified.", stage.VersionOutput);
        }
        catch (OperationCanceledException)
        {
            if (privilegedActivated || candidateInstalled || oldCoreWasStopped || Directory.Exists(backupPath))
            {
                var rollback = await RollBackCoreUpdateAsync(
                    stage.CoreType,
                    installPath,
                    backupPath,
                    candidateInstalled,
                    hadInstalledCore,
                    oldCoreWasStopped,
                    originalCoreWasRunning,
                    runningProfile,
                    batch,
                    privilegedActivated ? stage.PrivilegedToken : null);
                if (rollback.UpdateCommitted)
                    return new CoreUpdateApplyResult(false, false, originalCoreWasRunning,
                        CoreUpdateWorkflow.CommittedUpdateUnconfirmedDetail, stage.VersionOutput);
                if (!rollback.Completed)
                {
                    AddLog("update", rollback.FilesRestored
                        ? $"{stage.CoreType} previous files were restored, but the old Core process could not be relaunched."
                        : $"{stage.CoreType} rollback did not complete; previous files remain at {backupPath}.");
                }
            }
            throw;
        }
        catch (Exception exception)
        {
            AddLog("update", $"{stage.CoreType} apply failed: {exception.Message}");
            if (CurrentCoreRuntime.State is CoreRuntimeState.Stopping or CoreRuntimeState.Restarting or CoreRuntimeState.Starting)
            {
                SetCoreRuntime(CurrentCoreRuntime with
                {
                    State = CoreRuntimeState.Faulted,
                    ProcessIds = GetActiveCoreProcessIds(),
                    LastFailure = exception.Message,
                });
            }
            var rollback = new CoreUpdateRollbackResult(FilesRestored: true, CoreRestarted: true);
            if (privilegedActivated || candidateInstalled || oldCoreWasStopped || Directory.Exists(backupPath))
            {
                rollback = await RollBackCoreUpdateAsync(
                    stage.CoreType,
                    installPath,
                    backupPath,
                    candidateInstalled,
                    hadInstalledCore,
                    oldCoreWasStopped,
                    originalCoreWasRunning,
                    runningProfile,
                    batch,
                    privilegedActivated ? stage.PrivilegedToken : null);
            }
            if (rollback.UpdateCommitted)
                return new CoreUpdateApplyResult(false, false, originalCoreWasRunning,
                    CoreUpdateWorkflow.CommittedUpdateUnconfirmedDetail, stage.VersionOutput);
            var detail = rollback.Completed
                ? $"{exception.Message} The previous Core was restored."
                : rollback.FilesRestored
                    ? $"{exception.Message} The previous Core files were restored, but its process could not be restarted."
                    : $"{exception.Message} Rollback did not complete; see the runtime log for the retained backup path.";
            return new CoreUpdateApplyResult(false, rollback.Completed, originalCoreWasRunning, detail, stage.VersionOutput);
        }
        finally
        {
            try
            {
                if (Directory.Exists(candidatePath))
                {
                    Directory.Delete(candidatePath, recursive: true);
                }
            }
            catch (Exception exception)
            {
                AddLog("update", $"{stage.CoreType} candidate cleanup failed: {exception.Message}");
            }
            _coreGate.Release();
        }
    }

    private async Task<CoreUpdateRollbackResult> RollBackCoreUpdateAsync(
        ECoreType coreType,
        string installPath,
        string backupPath,
        bool candidateInstalled,
        bool hadInstalledCore,
        bool oldCoreWasStopped,
        bool wasRunning,
        ProfileItem? runningProfile,
        bool batch = false, string? privilegedToken = null)
    {
        var filesRestored = false;
        try
        {
            var result = await CoreUpdateWorkflow.RollBackAndRestoreAsync(
                async () =>
                {
                    // Do not stop an unrelated active Core when the target being updated was idle.
                    if (oldCoreWasStopped && wasRunning)
                    {
                        await StopCoreMonitorAsync();
                        await StopCoreAndConfirmAsync(CancellationToken.None);
                        SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
                    }
                    CoreUpdateWorkflow.RestorePreviousDirectory(
                        installPath, backupPath, candidateInstalled, hadInstalledCore);
                    filesRestored = true;
                },
                async () =>
                {
                    await CoreManager.Instance.Init(Config, OnCoreMessageAsync);
                    if (coreType == ECoreType.Xray)
                    {
                        _xrayPath = FindXrayExecutable(out _);
                    }
                },
                wasRunning && runningProfile is not null,
                async () =>
                {
                    PublishCoreUpdateProgress(coreType, "restarting-core", isComplete: false, success: false,
                        true, null, "Restarting the restored Core.", batch);
                    return (await StartCoreLockedAsync(runningProfile!, CancellationToken.None)).Success;
                },
                () => _macTunLauncher.TransitionUpdateAsync(coreType, privilegedToken, "update-rollback", CancellationToken.None));
            if (result.UpdateCommitted) AddLog("update", CoreUpdateWorkflow.CommittedUpdateUnconfirmedDetail);
            return result;
        }
        catch (Exception exception)
        {
            AddLog("update", $"{coreType} rollback failed: {exception.Message}");
            SetCoreRuntime(CurrentCoreRuntime with
            {
                State = CoreRuntimeState.Faulted,
                ProcessIds = GetActiveCoreProcessIds(),
                LastFailure = exception.Message,
            });
            return new CoreUpdateRollbackResult(filesRestored, CoreRestarted: false);
        }
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
        (coreInfo.CoreExes ?? [])
            .Select(name => Path.Combine(directory, Utils.GetExeName(name)))
            .FirstOrDefault(File.Exists);

    internal static void RemoveSupersededCoreExecutables(CoreInfo info, string candidate, string package)
    {
        var replacement = FindCoreExecutable(info, package)
            ?? throw new InvalidDataException("The replacement package has no core executable.");
        foreach (var name in info.CoreExes ?? [])
        {
            var fileName = Utils.GetExeName(name);
            if (fileName == Path.GetFileName(replacement)) continue;
            var oldAlias = Path.Combine(candidate, fileName);
            if (File.Exists(oldAlias)) File.Delete(oldAlias);
        }
    }

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
        CurrentCoreRuntime.State is CoreRuntimeState.Running or CoreRuntimeState.Faulted
        && CurrentCoreRuntime.CoreType == coreType
        && HasTrackedCoreProcesses;

    private static string GetArchiveSuffix(string downloadUrl)
    {
        var path = Uri.TryCreate(downloadUrl, UriKind.Absolute, out var uri) ? uri.AbsolutePath : downloadUrl;
        return path.EndsWith(".tar.gz", StringComparison.OrdinalIgnoreCase)
            ? ".tar.gz"
            : Path.GetExtension(path);
    }

    private static void CopyCoreDirectory(string sourceDirectory, string destinationDirectory)
    {
        Directory.CreateDirectory(destinationDirectory);
        foreach (var sourceFile in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.TopDirectoryOnly))
        {
            File.Copy(sourceFile, Path.Combine(destinationDirectory, Path.GetFileName(sourceFile)), overwrite: true);
        }
        foreach (var sourceSubdirectory in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.TopDirectoryOnly))
        {
            CopyCoreDirectory(sourceSubdirectory, Path.Combine(destinationDirectory, Path.GetFileName(sourceSubdirectory)));
        }
    }

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

    private async Task RunGeoUpdateAsync(bool useProxy, string scope)
    {
        try
        {
            PublishGeoUpdateProgress("downloading", isComplete: false, success: false, null);
            await using var operation = await _operations.EnterExclusiveAsync(
                _operations.ShutdownToken,
                allowReadOnlyObservations: true);
            var wasRunning = CurrentCoreRuntime.State == CoreRuntimeState.Running;
            await ApplyGeoFilesUpdateAsync(useProxy, operation.Token, scope: scope,
                beforeCommit: wasRunning ? async (rollback, token) => {
                    PublishGeoUpdateProgress("restarting-core", false, false, null);
                    try {
                        var restart = await RestartCoreAsync(token);
                        if (!restart.Success) throw new IOException("The serving core did not restart after the rule update.");
                    } catch {
                        PublishGeoUpdateProgress("rolling-back", false, false, null);
                        await rollback();
                        await RestartCoreAsync(CancellationToken.None);
                        throw;
                    }
                } : null);
            PublishGeoUpdateProgress("completed", isComplete: true, success: true, null);
        }
        catch (OperationCanceledException) when (_operations.IsStopping)
        {
            PublishGeoUpdateProgress("failed", isComplete: true, success: false, "Canceled during graceful shutdown.");
        }
        catch (Exception exception)
        {
            AddLog("update", $"GeoFiles update failed: {exception.Message}");
            PublishGeoUpdateProgress("failed", isComplete: true, success: false, exception.Message);
        }
    }

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

    internal static void CopyLatestGeoFilesForApply(string installPath, string stagingPath)
    {
        if (!Directory.Exists(installPath))
        {
            return;
        }
        foreach (var source in Directory.EnumerateFiles(installPath, "geo*", SearchOption.TopDirectoryOnly))
        {
            File.Copy(source, Path.Combine(stagingPath, Path.GetFileName(source)), overwrite: true);
        }
    }

    internal sealed record CoreUpdateStage(ECoreType CoreType, string InstallPath, string ArchivePath, string PackagePath, string VersionOutput, string? PrivilegedToken = null);
    private sealed record CoreUpdateBatchCheck(ECoreType CoreType, CoreUpdateCheckResult Result)
    {
        public UpdateResult Check => Result.Result;
        public bool IsUpToDate => Result.IsUpToDate;
        public bool CheckFailed => Result.Decision == UpdateCheckDecision.Failed;
        public bool AwaitingValidation => Result.AwaitingValidation;
    }
    private sealed record CoreUpdatePrepareResult(CoreUpdateStage? Stage, UpdateResult Check);
    private sealed record CoreUpdateApplyResult(bool Success, bool RolledBack, bool CoreWasRunning, string Detail, string? Version = null, bool AwaitingValidation = false);
}

internal static class CoreUpdateRuntimePolicy
{
    public static bool IsTargetRunning(ECoreType target, ECoreType runningCore, DateTimeOffset? startedAt) =>
        startedAt is not null && target == runningCore;
}

internal static class CoreUpdateWorkflow
{
    internal const string CommittedUpdateUnconfirmedDetail =
        "The new Core was already committed and has been retained in both update stores. " +
        "Final acknowledgement was interrupted; runtime health still requires confirmation. No rollback was performed.";
    public static void RestorePreviousDirectory(
        string installPath,
        string backupPath,
        bool candidateInstalled,
        bool hadInstalledCore)
    {
        if (candidateInstalled && Directory.Exists(installPath))
        {
            Directory.Delete(installPath, recursive: true);
        }
        if (hadInstalledCore && Directory.Exists(backupPath) && !Directory.Exists(installPath))
        {
            Directory.Move(backupPath, installPath);
        }
    }

    public static async Task<CoreUpdateRollbackResult> RollBackAndRestoreAsync(
        Func<Task> restoreFilesAsync,
        Func<Task> initializePreviousCoreAsync,
        bool wasRunning,
        Func<Task<bool>> restartPreviousCoreAsync,
        Func<Task>? rollbackTrustedCoreAsync = null)
    {
        if (rollbackTrustedCoreAsync is not null)
        {
            try { await rollbackTrustedCoreAsync(); }
            catch (MacHelperUpdateException exception) when (exception.Code == "update_already_committed")
            {
                // The helper's durable commit cannot be undone. Leave the matching
                // local candidate and runtime untouched; commit alone is not health.
                return new CoreUpdateRollbackResult(false, false, UpdateCommitted: true);
            }
        }
        await restoreFilesAsync();
        await initializePreviousCoreAsync();
        var restarted = !wasRunning || await restartPreviousCoreAsync();
        return new CoreUpdateRollbackResult(FilesRestored: true, CoreRestarted: restarted);
    }

    public static async Task<TResult> StageThenApplyAsync<TStage, TResult>(
        Func<Task<TStage>> stageAsync,
        Func<TStage, Task<TResult>> applyAsync)
    {
        var staged = await stageAsync();
        return await applyAsync(staged);
    }

    public static async Task<TResult> StageAllThenApplyAsync<TTarget, TStage, TResult>(
        IReadOnlyList<TTarget> targets,
        Func<TTarget, Task<TStage>> stageAsync,
        Func<IReadOnlyList<TStage>, Task<TResult>> applyAsync,
        Func<Task>? beforeApplyAsync = null)
    {
        var staged = new List<TStage>(targets.Count);
        foreach (var target in targets)
        {
            staged.Add(await stageAsync(target));
        }
        if (beforeApplyAsync is not null)
        {
            await beforeApplyAsync();
        }
        return await applyAsync(staged);
    }
}

internal sealed record CoreUpdateRollbackResult(bool FilesRestored, bool CoreRestarted, bool UpdateCommitted = false)
{
    public bool Completed => !UpdateCommitted && FilesRestored && CoreRestarted;
}
