using System.Net.Sockets;
using System.Net;
using System.Net.NetworkInformation;
using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Handler;
using ServiceLib.Handler.Builder;
using ServiceLib.Helper;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Dto;
using ServiceLib.Models.Entities;
using ServiceLib.Services;
using NLog;
using NLog.Config;
using NLog.Targets;
using v2rayN.WebAPI.Contracts;
using v2rayN.WebAPI.MacOS;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private readonly EventHub _events;
    private readonly LogBuffer _logs;
    private readonly IConfiguration _configuration;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly RuntimeExecutionContext _execution;
    private readonly CoreLifecycleService _coreLifecycle;
    private readonly IRuntimeConfigStore _configStore;
    private readonly CoreSettingsTransaction _settingsTransaction;
    private readonly ModuleUpdateCoordinator _moduleUpdates;
    private RuntimeOperationCoordinator _operations => _execution.Operations;
    private RuntimeMutationGate _mutations => _execution.Mutations;
    private SemaphoreSlim _coreGate => _execution.CoreGate;
    private SemaphoreSlim _regionalPresetGate => _execution.RegionalPresetGate;

    public V2rayRuntime(EventHub events, LogBuffer logs, IConfiguration configuration,
        IHostApplicationLifetime lifetime, RuntimeOperationCoordinator operations,
        IRuntimeConfigStore? configStore = null)
    {
        _events = events; _logs = logs; _configuration = configuration; _lifetime = lifetime;
        _execution = new RuntimeExecutionContext(operations);
        _configStore = configStore ?? new ServiceLibRuntimeConfigStore();
        _coreLifecycle = new CoreLifecycleService(_execution, () => CoreManager.Instance.CoreStop(),
            _macTunLauncher.ConfirmCleanupAsync, IsListeningAsync, OnCoreRuntimeChanged,
            message => AddLog("core", message), CoreProcessTracker.GetActiveProcesses);
        _settingsTransaction = new CoreSettingsTransaction(_execution, _configStore);
        _moduleUpdates = new ModuleUpdateCoordinator(_execution);
    }
    private readonly object _subscriptionGate = new();
    private readonly object _speedtestGate = new();
    private readonly Dictionary<string, Task> _subscriptionTasks = new(StringComparer.Ordinal);
    private SpeedtestService? _speedtestService;
    private Task? _speedtestTask;
    private CancellationTokenSource? _speedtestCancellation;
    private string? _xrayPath;
    private readonly TrafficAverageWindow _trafficWindow = new();
    private readonly InstalledXrayVersion _installedXrayVersion = new();
    private bool _initialized;
    private readonly MacTunCoreLauncher _macTunLauncher = MacTunCoreLauncher.ForCurrentApp();
    private bool _restoring;
    private int _restoreAndRestartRequested;

    private Config Config => _configStore.Current;
    private CoreRuntimeSnapshot CurrentCoreRuntime => _coreLifecycle.Snapshot;
    public bool RestoreAndRestartRequested => Volatile.Read(ref _restoreAndRestartRequested) != 0;

    public int[] GetCoreProcessIds() => GetActiveCoreProcessIds();

    public string? GetCoreRuntimeProfileId() => CurrentCoreRuntime.ProfileId;

    public string GetCoreRuntimeState() => CurrentCoreRuntime.State.ToString().ToLowerInvariant();

    private void SetCoreRuntime(CoreRuntimeSnapshot snapshot) => _coreLifecycle.SetSnapshot(snapshot);

    private void OnCoreRuntimeChanged(CoreRuntimeSnapshot snapshot)
    {
        if (snapshot.State != CoreRuntimeState.Running)
        {
            _trafficWindow.Clear();
            StatisticsManager.Instance.ResetSample();
        }
        _events.Publish("core-state", new
        {
            state = snapshot.State.ToString().ToLowerInvariant(),
            profileId = snapshot.ProfileId,
            coreType = snapshot.CoreType is { } coreType
                ? System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(coreType.ToString())
                : null,
            startedAt = snapshot.StartedAt,
            proxyPort = snapshot.ProxyPort,
            apiPort = snapshot.ApiPort,
            processIds = snapshot.ProcessIds,
            lastFailure = snapshot.LastFailure,
        });
    }

    private Task StartCoreMonitorAsync() => _coreLifecycle.StartMonitorAsync();
    private Task StopCoreMonitorAsync() => _coreLifecycle.StopMonitorAsync();
    private CoreProcessIdentity[] GetActiveCoreProcesses() => _coreLifecycle.GetActiveProcesses();
    private int[] GetActiveCoreProcessIds() => _coreLifecycle.GetActiveProcessIds();
    private bool HasTrackedCoreProcesses => _coreLifecycle.HasTrackedProcesses;
    private void SetTrackedCoreProcesses(IEnumerable<CoreProcessIdentity> processes) => _coreLifecycle.SetTrackedProcesses(processes);
    private Task StopCoreAndConfirmAsync(CancellationToken token) => _coreLifecycle.StopAndConfirmAsync(token);

    public async Task InitializeAsync(CancellationToken cancellationToken, bool suppressCoreAutostart = false)
    {
        var restoreState = await LoadRestoreRuntimeStateAsync(cancellationToken);
        var updateStatePath = WebUpdateRuntimeStatePath;
        var updateRuntimeState = restoreState is null
            ? await LoadRuntimeRestartIntentAsync(updateStatePath, cancellationToken)
            : null;
        var startupRuntimeIntent = restoreState ?? updateRuntimeState;
        if (!AppManager.Instance.InitApp())
        {
            throw new InvalidOperationException("ServiceLib could not load its configuration.");
        }
        // Finish a previously interrupted DB + JSON rollback before any core
        // or background mutator can observe a partially restored configuration.
        await _configStore.RecoverPendingRestoreAsync();
        ConfigureServiceLibConsoleLogging();

        if (!AppManager.Instance.InitComponents())
        {
            throw new InvalidOperationException("ServiceLib component initialization failed.");
        }

        await _mutations.RunAsync(async () =>
        {
            EnsureInboundDefaults(Config);
            EnsureCoreTypeMappings();
            // Migrate only API-owned preference identifiers; no ServiceLib code changes.
            Config.CheckUpdateItem.SelectedCoreTypes = NormalizeWebUpdateTargets(Config.CheckUpdateItem.SelectedCoreTypes);
            Config.CheckUpdateItem.CheckPreReleaseCoreTypes = NormalizeWebUpdateTargets(Config.CheckUpdateItem.CheckPreReleaseCoreTypes);
            var proxyPortOverride = _configuration.GetValue<int?>("V2RAYN_WEB_PROXY_PORT");
            if (proxyPortOverride is <= 0 or > 65535)
            {
                throw new InvalidOperationException("V2RAYN_WEB_PROXY_PORT must be a valid TCP/UDP port (1-65535).");
            }
            if (proxyPortOverride is int configuredProxyPort)
            {
                Config.Inbound[0].LocalPort = configuredProxyPort;
            }
            if (_configuration.GetValue<bool?>("V2RAYN_WEB_PROXY_LISTEN_ALL") is bool allowProxyFromLan)
            {
                Config.Inbound[0].AllowLANConn = allowProxyFromLan;
            }
            await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
        });
        await ConfigHandler.InitBuiltinDNS(Config);
        await BuiltinDnsProfileBootstrap.EnsureAsync(
            Config,
            async () => await AppManager.Instance.DNSItems() ?? [],
            ConfigHandler.SaveDNSItems);
        await ConfigHandler.InitBuiltinFullConfigTemplate(Config);
        // Keep startup aligned with Desktop's StatusBarViewModel. In particular,
        // InitBuiltinRouting owns the RoutingIndexId -> IsActive migration and must
        // run even when a restored Desktop database already has routing rows.
        await ConfigHandler.InitBuiltinRouting(Config);
        _ = await ConfigHandler.GetDefaultRouting(Config);
        var restoredSubscriptions = await AppManager.Instance.SubItems() ?? [];
        var normalizedSubIndexId = NormalizeSelectedSubscriptionId(
            Config.SubIndexId,
            restoredSubscriptions.Select(item => item.Id).ToArray());
        if (Config.SubIndexId != normalizedSubIndexId)
        {
            AddLog("restore", "The selected subscription group no longer exists; normalized the selection to all profiles.");
            Config.SubIndexId = normalizedSubIndexId;
        }
        var selectedProfileId = Config.IndexId;
        var defaultProfile = await ConfigHandler.GetDefaultServer(Config);
        await _mutations.RunAsync(() => EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync()));
        await ProfileExManager.Instance.Init();
        await CertPemManager.Instance.Init(Config);
        // The native macOS host routes TUN launches through its signed XPC helper.
        if (OperatingSystem.IsMacOS()) CoreManager.Instance.PrivilegedCoreLauncher = _macTunLauncher;
        await CoreManager.Instance.Init(Config, OnCoreMessageAsync);
        if (Config.GuiItem.EnableStatistics || Config.GuiItem.DisplayRealTimeSpeed)
        {
            await StatisticsManager.Instance.Init(Config, OnStatisticsUpdateAsync);
        }
        _xrayPath = FindXrayExecutable(out var missingXrayMessage);
        if (_xrayPath is null)
        {
            AddLog("core", missingXrayMessage);
        }

        _initialized = true;
        AddLog("web", "serviceLib.initialized");
        StartScheduledOperations(cancellationToken);

        if (startupRuntimeIntent is not null)
        {
            if (!RuntimeRestartRecovery.ShouldRecoverCore(startupRuntimeIntent, suppressCoreAutostart))
            {
                if (suppressCoreAutostart && startupRuntimeIntent.WasRunning)
                {
                    AddLog("core", "Core startup was suppressed until first-run Management Key setup is complete.");
                }
            }
            else
            {
                await RuntimeRestartRecovery.RecoverAsync(
                    startupRuntimeIntent,
                    selectedProfileId,
                    defaultProfile?.IndexId,
                    async (profileId, _) => await AppManager.Instance.GetProfileItem(profileId) is not null,
                    StartCoreAsync,
                    message => AddLog(restoreState is not null ? "restore" : "update", message),
                    cancellationToken);
            }
            if (restoreState is not null)
            {
                await CommitRestoreRuntimeStateAsync();
            }
        }
        else if (RuntimeRestartRecovery.ShouldAutoStart(
            startupRuntimeIntent,
            _configuration.GetValue("V2RAYN_WEB_AUTOSTART", false),
            suppressCoreAutostart))
        {
            var result = await StartCoreAsync(null, cancellationToken);
            if (!result.Success)
            {
                AddLog("core", result.MessageKey);
            }
        }
        else if (suppressCoreAutostart)
        {
            AddLog("core", "Core autostart was suppressed until first-run Management Key setup is complete.");
        }
    }

    public async Task ShutdownAsync(CancellationToken cancellationToken)
    {
        var steps = new List<ShutdownCleanupStep>
        {
            new("restore shutdown request", async deadline =>
            {
                await WaitForRestoreShutdownRequestAsync(deadline.Token);
                return true;
            }),
            new("scheduled operations stop", deadline => StopScheduledOperationsAsync(deadline.Token)),
            new("operation drain", async deadline =>
            {
                var drained = await _operations.StopAndDrainAsync(deadline.Token, deadline.Remaining);
                if (!drained)
                {
                    AddLog("web", "Shutdown operation drain timed out; skipped all Core, state-save, and SQLite cleanup.");
                }
                return drained;
            }),
        };

        var saveServiceLibState = _initialized && !_restoring;
        if (saveServiceLibState)
        {
            steps.AddRange(ShutdownStatisticsCheckpoint.WrapCoreStop(
                () => StatisticsManager.Instance.SaveTo(), async deadline =>
            {
                try
                {
                    await StopCoreMonitorAsync();
                    await StopCoreAndConfirmAsync(deadline.Token);
                    SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
                    return true;
                }
                catch (Exception exception)
                {
                    SetCoreRuntime(CurrentCoreRuntime with
                    {
                        State = CoreRuntimeState.Faulted,
                        ProcessIds = GetActiveCoreProcessIds(),
                        LastFailure = exception.Message,
                    });
                    throw;
                }
            }, message => AddLog("web", message)));
            steps.Add(new("profile save", async _ =>
            {
                await ProfileExManager.Instance.SaveTo();
                return true;
            }));
            steps.Add(new("statistics close", async _ =>
            {
                await StatisticsManager.Instance.CloseAsync();
                return true;
            }));
            steps.Add(new("configuration save", async deadline =>
            {
                await _mutations.RunAsync(
                    () => EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync()),
                    deadline.Token);
                return true;
            }));
            steps.Add(new("database close", async _ =>
            {
                await SQLiteHelper.Instance.DisposeDbConnectionAsync();
                return true;
            }));
        }

        var completed = await ShutdownCleanupSequence.RunAsync(
            steps,
            RuntimeShutdownBudgets.RuntimeCleanup,
            cancellationToken,
            message => AddLog("web", message),
            ShutdownDiagnostics.SetStage);
        if (completed && saveServiceLibState)
        {
            AddLog("web", "serviceLib.stopped");
        }
    }

    internal static async Task EnsureConfigSaveSucceededAsync(Func<Task<int>> save)
    {
        if (await save() != 0)
        {
            throw new IOException("ServiceLib could not persist the configuration.");
        }
    }

    public async Task<IReadOnlyList<SubscriptionView>> GetSubscriptionsAsync()
    {
        var items = await AppManager.Instance.SubItems() ?? [];
        return items.Select(ToSubscriptionView).ToArray();
    }

    public async Task<SubscriptionMutationResult> AddSubscriptionAsync(SubscriptionInput input)
    {
        if (!TryValidateSubscription(input, out var code, out var messageKey))
        {
            return new(false, code, messageKey, null);
        }

        var item = ToSubItem(input, null);
        var result = await _mutations.RunAsync(() => ConfigHandler.AddSubItem(Config, item));
        if (result != 0)
        {
            return new(false, "subscription_save_failed", ApiMessageKeys.SubscriptionSaveFailed, null);
        }

        var saved = await AppManager.Instance.GetSubItem(item.Id);
        return saved is null
            ? new(false, "subscription_save_failed", ApiMessageKeys.SubscriptionSaveFailed, null)
            : new(true, "ok", ApiMessageKeys.SubscriptionAdded, ToSubscriptionView(saved));
    }

    public async Task<SubscriptionMutationResult> UpdateSubscriptionAsync(string id, SubscriptionInput input)
    {
        if (!TryValidateSubscription(input, out var code, out var messageKey))
        {
            return new(false, code, messageKey, null);
        }

        return await _mutations.RunAsync(async () =>
        {
            var existing = await AppManager.Instance.GetSubItem(id);
            if (existing is null)
            {
                return new SubscriptionMutationResult(false, "subscription_not_found", ApiMessageKeys.SubscriptionNotFound, null);
            }

            var item = ToSubItem(input, existing);
            item.Id = id;
            var result = await ConfigHandler.AddSubItem(Config, item);
            if (result != 0)
            {
                return new SubscriptionMutationResult(false, "subscription_save_failed", ApiMessageKeys.SubscriptionSaveFailed, null);
            }

            var saved = await AppManager.Instance.GetSubItem(id);
            return saved is not null
                ? new SubscriptionMutationResult(true, "ok", ApiMessageKeys.SubscriptionSaved, ToSubscriptionView(saved))
                : new SubscriptionMutationResult(false, "subscription_save_failed", ApiMessageKeys.SubscriptionSaveFailed, null);
        });
    }

    public async Task<OperationView> DeleteSubscriptionAsync(string id)
    {
        var subscription = await AppManager.Instance.GetSubItem(id);
        if (subscription is null)
        {
            return OperationView.Fail("subscription_not_found", ApiMessageKeys.SubscriptionNotFound);
        }

        var selectedProfile = await AppManager.Instance.GetProfileItem(Config.IndexId);
        var removesCurrentProfile = selectedProfile?.Subid == id;
        if (removesCurrentProfile)
        {
            await StopCoreAsync(CancellationToken.None);
        }

        await _mutations.RunAsync(async () =>
        {
            if (await ConfigHandler.DeleteSubItem(Config, id) != 0)
            {
                throw new IOException("ServiceLib could not delete the subscription.");
            }
            if (removesCurrentProfile)
            {
                _ = await ConfigHandler.GetDefaultServer(Config);
                await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
            }
        });

        AddLog("subscription", ApiMessageKeys.SubscriptionDeleted);
        return OperationView.Ok(ApiMessageKeys.SubscriptionDeleted);
    }

    public bool StartSubscriptionUpdate(string id, bool useProxy)
    {
        return StartSubscriptionUpdateTask(id, useProxy, _operations.ShutdownToken) is not null;
    }

    private Task? StartSubscriptionUpdateTask(string id, bool useProxy, CancellationToken operationToken)
    {
        lock (_subscriptionGate)
        {
            var hasConflictingUpdate = _subscriptionTasks.Any(pair =>
                !pair.Value.IsCompleted
                && (pair.Key.Length == 0 || id.Length == 0 || pair.Key == id));
            if (hasConflictingUpdate)
            {
                return null;
            }

            var task = Task.Run(async () =>
            {
                try
                {
                    await using var operation = await _operations.EnterOperationAsync(operationToken);
                    await _mutations.RunAsync(async () =>
                    {
                        await SubscriptionHandler.UpdateProcess(Config, id, useProxy, (success, message) =>
                        {
                            var payload = new
                            {
                                subscriptionId = id,
                                success,
                                code = success ? "ok" : "subscription_update_progress",
                                messageKey = success ? ApiMessageKeys.SubscriptionSaved : ApiMessageKeys.SubscriptionUpdateProgress,
                                rawLog = message,
                            };
                            _events.Publish("subscription-progress", payload);
                            AddLog("subscription", message);
                            return Task.CompletedTask;
                        });

                        operation.Token.ThrowIfCancellationRequested();
                        await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
                        await UpdateSubscriptionTimestampLockedAsync(id);
                    }, operation.Token);
                    _events.Publish("profiles-changed", new { subscriptionId = id });
                }
                catch (OperationCanceledException) when (_operations.IsStopping || operationToken.IsCancellationRequested)
                {
                    // Expected during graceful service shutdown.
                }
                catch (Exception ex)
                {
                    AddLog("subscription", ex.Message);
                }
                finally
                {
                    lock (_subscriptionGate)
                    {
                        _subscriptionTasks.Remove(id);
                    }
                }
            });

            _subscriptionTasks[id] = task;
            return task;
        }
    }

    public async Task<IReadOnlyList<ProfileView>> GetProfilesAsync(string? subscriptionId, string? filter)
    {
        var groupId = subscriptionId ?? Config.SubIndexId ?? string.Empty;
        var profiles = await AppManager.Instance.ProfileItems(groupId) ?? [];
        var subscriptions = (await AppManager.Instance.SubItems() ?? []).ToDictionary(item => item.Id, item => item.Remarks);
        var extensions = await ProfileExManager.Instance.GetProfileExs();
        var extensionMap = extensions.ToDictionary(item => item.IndexId);
        var statistics = (Config.GuiItem.EnableStatistics ? StatisticsManager.Instance.ServerStat : null) ?? [];
        var statisticsMap = statistics.ToDictionary(item => item.IndexId);
        var query = filter?.Trim();

        return profiles
            .Where(item => string.IsNullOrEmpty(query)
                || Utils.IsRegexMatch(item.Remarks, query)
                || Utils.IsRegexMatch(item.Address, query))
            .Select(item =>
            {
                extensionMap.TryGetValue(item.IndexId, out var extension);
                statisticsMap.TryGetValue(item.IndexId, out var statistic);
                var delay = extension?.Delay ?? 0;
                var speed = extension?.Speed ?? 0;
                return new ProfileView(
                    item.IndexId,
                    item.Remarks,
                    System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(item.ConfigType.ToString()),
                    item.Address,
                    item.Port,
                    item.GetNetwork(),
                    item.StreamSecurity,
                    item.Subid,
                    subscriptions.GetValueOrDefault(item.Subid),
                    System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(AppManager.Instance.GetCoreType(item, item.ConfigType).ToString()),
                    extension?.Sort ?? 0,
                    delay,
                    speed,
                    extension?.IpInfo,
                    statistic?.TodayUp ?? 0,
                    statistic?.TodayDown ?? 0,
                    statistic?.TotalUp ?? 0,
                    statistic?.TotalDown ?? 0,
                    item.IndexId == Config.IndexId,
                    !item.IsComplex() && item.Port > 0);
            })
            .OrderBy(item => item.Sort)
            .ToArray();
    }

    public async Task<ProfileItem?> GetProfileDetailsAsync(string profileId) =>
        await AppManager.Instance.GetProfileItem(profileId);

    public async Task<StatusView> GetStatusAsync()
    {
        var selectedProfile = await AppManager.Instance.GetProfileItem(Config.IndexId);
        var profileItems = await AppManager.Instance.ProfileItems(string.Empty) ?? [];
        var subscriptions = await AppManager.Instance.SubItems() ?? [];
        var snapshot = CurrentCoreRuntime;
        var processIds = GetActiveCoreProcessIds();
        var listenerDefinitions = snapshot.ProxyPort.HasValue && snapshot.State != CoreRuntimeState.Stopped
            ? snapshot.Listeners
            : GetConfiguredListenerSnapshots();
        var listeners = new List<ListenerView>(listenerDefinitions.Length);
        foreach (var listener in listenerDefinitions)
        {
            listeners.Add(new ListenerView(
                listener.Name,
                listener.Protocols,
                listener.ListenAddress,
                listener.Port,
                await IsListeningAsync(listener.Port, CancellationToken.None)));
        }

        var mainListener = listeners.FirstOrDefault(listener => listener.Name == "local");
        var listening = mainListener?.Listening == true;
        var inbound = Config.Inbound.FirstOrDefault();
        var sniffingEnabled = inbound?.SniffingEnabled ?? false;
        var sniffingTypes = NormalizeDestOverride(sniffingEnabled, inbound?.DestOverride);
        var coreRunning = snapshot.State == CoreRuntimeState.Running && processIds.Length > 0 && listening;
        if (snapshot.State == CoreRuntimeState.Running && !coreRunning)
        {
            snapshot = snapshot with
            {
                State = CoreRuntimeState.Faulted,
                ProcessIds = processIds,
                LastFailure = processIds.Length == 0
                    ? "The tracked Core child process exited unexpectedly."
                    : "The running Core no longer owns its expected proxy listener.",
            };
            SetCoreRuntime(snapshot);
        }

        var runningProfile = string.IsNullOrEmpty(snapshot.ProfileId)
            ? null
            : await AppManager.Instance.GetProfileItem(snapshot.ProfileId);
        var configuredProxyPort = Config.Inbound.FirstOrDefault()?.LocalPort;
        return new StatusView(
            coreRunning,
            snapshot.CoreType is { } coreType
                ? System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(coreType.ToString())
                : null,
            selectedProfile?.IndexId,
            selectedProfile?.Remarks,
            snapshot.StartedAt,
            listeners.ToArray(),
            !string.IsNullOrEmpty(_xrayPath),
            Utils.GetRuntimeInfo(),
            profileItems.Count,
            subscriptions.Count,
            DateTimeOffset.UtcNow,
            Config.GuiItem.EnableStatistics,
            coreRunning ? _trafficWindow.Read(DateTimeOffset.UtcNow) : null,
            snapshot.State.ToString().ToLowerInvariant(),
            configuredProxyPort,
            snapshot.State == CoreRuntimeState.Stopped ? null : snapshot.ProxyPort,
            snapshot.ProfileId,
            runningProfile?.Remarks,
            snapshot.ApiPort,
            processIds,
            snapshot.LastFailure,
            WebBuildIdentity.Current.Version,
            WebBuildIdentity.Current.Commit,
            WebBuildIdentity.Current.Rid,
            WebBuildIdentity.Current.BuildDate,
            sniffingEnabled,
            sniffingTypes,
            WebApiCapabilities.Current,
            Config.GuiItem.EnableStatistics || Config.GuiItem.DisplayRealTimeSpeed,
            await _installedXrayVersion.ReadAsync(_xrayPath));

    }

    public async Task<OperationView> SelectProfileAsync(string profileId, CancellationToken cancellationToken, bool connect = true)
    {
        var profile = await AppManager.Instance.GetProfileItem(profileId);
        if (profile is null)
        {
            return OperationView.Fail("profile_not_found", ApiMessageKeys.ProfileNotFound);
        }

        if (connect) return await StartCoreAsync(profile, cancellationToken, selectProfile: true);
        await _coreGate.WaitAsync(cancellationToken);
        try
        {
            if (CurrentCoreRuntime.State != CoreRuntimeState.Stopped)
                return OperationView.Fail("core_selection_requires_stop", ApiMessageKeys.CommonInvalidInput);
            await _mutations.RunAsync(async () => {
                Config.IndexId = profile.IndexId;
                await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
            });
            return OperationView.Ok(ApiMessageKeys.CommonCompleted);
        }
        finally { _coreGate.Release(); }
    }

    public async Task<OperationView> StartCoreAsync(string? profileId, CancellationToken cancellationToken)
    {
        ProfileItem? profile = null;
        if (!string.IsNullOrWhiteSpace(profileId))
        {
            profile = await AppManager.Instance.GetProfileItem(profileId);
            if (profile is null)
            {
                return OperationView.Fail("profile_not_found", ApiMessageKeys.ProfileNotFound);
            }
        }

        return await StartCoreAsync(profile, cancellationToken);
    }

    private async Task<OperationView> StartCoreAsync(ProfileItem? requestedProfile, CancellationToken cancellationToken, bool selectProfile = false)
    {
        return await _coreLifecycle.ExecuteAsync(() => StartCoreLockedAsync(requestedProfile, cancellationToken, selectProfile), cancellationToken);
    }

    private async Task<OperationView> StartCoreLockedAsync(ProfileItem? requestedProfile, CancellationToken cancellationToken, bool selectProfile = false)
    {
        var profile = requestedProfile ?? await GetDefaultProfileAsync();
        if (profile is null)
        {
            return OperationView.Fail("profile_not_selected", ApiMessageKeys.ProfileNoneSelected);
        }

        var current = CurrentCoreRuntime;
        if (!selectProfile
            && current.State == CoreRuntimeState.Running
            && current.ProfileId == profile.IndexId
            && HasTrackedCoreProcesses)
        {
            return OperationView.Ok(ApiMessageKeys.CoreStarted, new { profileId = profile.IndexId, alreadyRunning = true });
        }

        var preflight = await BuildAndValidateCoreLaunchAsync(profile);
        if (preflight.Failure is { } preflightFailure)
        {
            return preflightFailure;
        }

        if (selectProfile)
        {
            await _mutations.RunAsync(async () =>
            {
                Config.IndexId = profile.IndexId;
                await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
            });
        }

        return await LaunchPreflightedCoreLockedAsync(preflight, cancellationToken);
    }

    private async Task<ProfileItem?> GetDefaultProfileAsync() => await _mutations.RunAsync(async () =>
    {
        var selected = await ConfigHandler.GetDefaultServer(Config);
        if (selected is not null)
        {
            await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
        }
        return selected;
    });

    private async Task<CoreLaunchPreflightResult> BuildAndValidateCoreLaunchAsync(ProfileItem profile)
    {
        var helper = Config.TunModeItem.EnableTun ? await _macTunLauncher.ProbeAsync() : null;
        var preflight = await CoreLaunchPreflight.BuildAndValidateAsync(MacNativeTunConfig.ForLaunch(Config, OperatingSystem.IsMacOS()), profile, coreType =>
        {
            var coreInfo = CoreInfoManager.Instance.GetCoreInfo(coreType);
            var executable = CoreInfoManager.Instance.GetCoreExecFile(coreInfo, out var missingCoreMessage);
            if (!string.IsNullOrEmpty(executable))
            {
                return null;
            }

            AddLog("core", missingCoreMessage);
            return OperationView.Fail("core_binary_missing", ApiMessageKeys.CoreBinaryMissing,
                new { coreType = coreType.ToString() });
        }, built => MacTunLaunchPolicy.Validate(built, OperatingSystem.IsMacOS(), helper?.Success == true));

        if (preflight.Failure?.Code == "profile_validation_failed")
        {
            foreach (var message in preflight.BuiltContext.CombinedValidatorResult.Errors
                         .Concat(preflight.BuiltContext.CombinedValidatorResult.Warnings))
            {
                AddLog("core-validation", message);
            }
        }

        if (preflight.Success)
        {
            RuntimeListenerSnapshot[] currentlyOwnedListeners = HasTrackedCoreProcesses
                ? CurrentCoreRuntime.Listeners
                : [];
            foreach (var listener in GetConfiguredListenerSnapshots())
            {
                if (await IsProjectedListenerUnavailableAsync(listener, currentlyOwnedListeners, CancellationToken.None))
                {
                    return new CoreLaunchPreflightResult(
                        preflight.Profile,
                        preflight.BuiltContext,
                        OperationView.Fail("proxy_port_in_use", ApiMessageKeys.CorePortInUse,
                            new { port = listener.Port, listener = listener.Name }));
                }
            }
        }

        return preflight;
    }

    private async Task<OperationView> LaunchPreflightedCoreLockedAsync(
        CoreLaunchPreflightResult preflight,
        CancellationToken cancellationToken)
    {
        var profile = preflight.Profile;
        var built = preflight.BuiltContext;
        var port = Config.Inbound.FirstOrDefault()?.LocalPort ?? 0;
        if (!HasTrackedCoreProcesses && CurrentCoreRuntime.State == CoreRuntimeState.Stopped
            && await IsListeningAsync(port, cancellationToken))
        {
            return OperationView.Fail("proxy_port_in_use", ApiMessageKeys.CorePortInUse, new { port });
        }

        if (CurrentCoreRuntime.State != CoreRuntimeState.Stopped || HasTrackedCoreProcesses)
        {
            SetCoreRuntime(CurrentCoreRuntime with { State = CoreRuntimeState.Stopping, LastFailure = null });
            try
            {
                await StopCoreMonitorAsync();
                await StopCoreAndConfirmAsync(cancellationToken);
                SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
            }
            catch (Exception exception)
            {
                var failedStop = CurrentCoreRuntime with
                {
                    State = CoreRuntimeState.Faulted,
                    ProcessIds = GetActiveCoreProcessIds(),
                    LastFailure = exception.Message,
                };
                SetCoreRuntime(failedStop);
                AddLog("core", $"Core stop before launch failed: {exception}");
                return OperationView.Fail("core_stop_failed", ApiMessageKeys.CoreStopFailed,
                    new { detail = exception.Message, processIds = failedStop.ProcessIds });
            }
        }

        var expectedCoreType = built.PreSocksResult?.Context.RunCoreType ?? built.MainResult.Context.RunCoreType;
        var listeners = GetConfiguredListenerSnapshots();
        SetCoreRuntime(new CoreRuntimeSnapshot(
            CoreRuntimeState.Starting,
            profile.IndexId,
            expectedCoreType,
            null,
            listeners.FirstOrDefault(listener => listener.Name == "local")?.Port,
            AppManager.Instance.StatePort,
            listeners,
            [],
            null));

        try
        {
            var existingProcessIds = CoreProcessTracker.CaptureExistingProcessIds();
            var expectedExecutablePaths = GetExpectedCoreExecutablePaths(built);
            var expectedConfigPaths = GetExpectedCoreConfigPaths(built);
            try
            {
                await CoreManager.Instance.LoadCore(built.MainResult.Context, built.PreSocksResult?.Context);
            }
            finally
            {
                var tracked = OperatingSystem.IsMacOS()
                    ? CoreProcessTracker.CaptureOwnedProcesses(CoreManager.Instance.GetOwnedCoreProcessIds())
                    : CoreProcessTracker.CaptureStartedProcesses(existingProcessIds, expectedExecutablePaths, expectedConfigPaths);
                SetTrackedCoreProcesses(tracked.Concat(_macTunLauncher.CaptureIdentities()));
            }
            var started = await WaitForListenerAsync(port, cancellationToken);
            var processIds = GetActiveCoreProcessIds();
            if (!started || processIds.Length == 0)
            {
                var failure = !started
                    ? "The Core process did not open its configured proxy listener."
                    : "The Web runtime could not identify a live Core child process.";
                try
                {
                    await StopCoreAndConfirmAsync(CancellationToken.None);
                    processIds = GetActiveCoreProcessIds();
                }
                catch (Exception stopException)
                {
                    failure += $" Cleanup also failed: {stopException.Message}";
                }
                SetCoreRuntime(CurrentCoreRuntime with
                {
                    State = CoreRuntimeState.Faulted,
                    ProcessIds = processIds,
                    LastFailure = failure,
                });
                AddLog("core", failure);
                _events.Publish("status", await GetStatusAsync());
                return OperationView.Fail("core_start_failed", ApiMessageKeys.CoreStartFailed,
                    new { profileId = profile.IndexId, detail = failure, processIds });
            }

            SetCoreRuntime(CurrentCoreRuntime with
            {
                State = CoreRuntimeState.Running,
                CoreType = AppManager.Instance.RunningCoreType,
                StartedAt = DateTimeOffset.UtcNow,
                ProcessIds = processIds,
                LastFailure = null,
            });
            await StartCoreMonitorAsync();
            AddLog("core", ApiMessageKeys.CoreStarted);
            _events.Publish("status", await GetStatusAsync());
            return OperationView.Ok(ApiMessageKeys.CoreStarted, new { profileId = profile.IndexId, processIds });
        }
        catch (Exception exception)
        {
            AddLog("core", $"Core start failed: {exception}");
            var processIds = GetActiveCoreProcessIds();
            if (CurrentCoreRuntime.State == CoreRuntimeState.Starting || processIds.Length > 0)
            {
                try
                {
                    await StopCoreAndConfirmAsync(CancellationToken.None);
                    processIds = GetActiveCoreProcessIds();
                }
                catch (Exception stopException)
                {
                    AddLog("core", $"Core start cleanup failed: {stopException}");
                }
            }
            SetCoreRuntime(CurrentCoreRuntime with
            {
                State = CoreRuntimeState.Faulted,
                ProcessIds = processIds,
                LastFailure = exception.Message,
            });
            _events.Publish("status", await GetStatusAsync());
            return OperationView.Fail("core_start_failed", ApiMessageKeys.CoreStartFailed,
                new { profileId = profile.IndexId, detail = exception.Message, processIds });
        }
    }

    internal static OperationView? GetTunLaunchRejection(CoreConfigContextBuilderAllResult built) =>
        CoreLaunchPreflight.GetTunLaunchRejection(built);

    internal static string NormalizeSelectedSubscriptionId(string? selectedId, IReadOnlyCollection<string> availableIds) =>
        string.IsNullOrEmpty(selectedId) || availableIds.Contains(selectedId, StringComparer.Ordinal)
            ? selectedId ?? string.Empty
            : string.Empty;

    public async Task<OperationView> StopCoreAsync(CancellationToken cancellationToken)
    {
        return await _coreLifecycle.ExecuteAsync(() => StopCoreLockedAsync(cancellationToken), cancellationToken);
    }

    private async Task<OperationView> StopCoreLockedAsync(CancellationToken cancellationToken)
    {
        if (CurrentCoreRuntime.State == CoreRuntimeState.Stopped && !HasTrackedCoreProcesses)
        {
            return OperationView.Ok(ApiMessageKeys.CoreStopped);
        }

        SetCoreRuntime(CurrentCoreRuntime with { State = CoreRuntimeState.Stopping, LastFailure = null });
        try
        {
            await StopCoreMonitorAsync();
            await StopCoreAndConfirmAsync(cancellationToken);
            SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
            AddLog("core", ApiMessageKeys.CoreStopped);
            _events.Publish("status", await GetStatusAsync());
            return OperationView.Ok(ApiMessageKeys.CoreStopped);
        }
        catch (Exception exception)
        {
            var processIds = GetActiveCoreProcessIds();
            SetCoreRuntime(CurrentCoreRuntime with
            {
                State = CoreRuntimeState.Faulted,
                ProcessIds = processIds,
                LastFailure = exception.Message,
            });
            AddLog("core", $"Core stop failed: {exception}");
            _events.Publish("status", await GetStatusAsync());
            return OperationView.Fail("core_stop_failed", ApiMessageKeys.CoreStopFailed,
                new { detail = exception.Message, processIds });
        }
    }

    public async Task<OperationView> RestartCoreAsync(CancellationToken cancellationToken)
    {
        return await _coreLifecycle.ExecuteAsync(() => RestartCoreLockedAsync(cancellationToken), cancellationToken);
    }

    private async Task<OperationView> RestartCoreLockedAsync(CancellationToken cancellationToken)
    {
        var previous = CurrentCoreRuntime;
            if (previous.State is not (CoreRuntimeState.Running or CoreRuntimeState.Faulted)
                || string.IsNullOrEmpty(previous.ProfileId))
            {
                return OperationView.Fail("core_not_running", ApiMessageKeys.CoreNotRunning,
                    new { runtimeState = previous.State.ToString(), processIds = GetActiveCoreProcessIds() });
            }

            var profile = await AppManager.Instance.GetProfileItem(previous.ProfileId);
            if (profile is null)
            {
                return OperationView.Fail("profile_not_found", ApiMessageKeys.ProfileNotFound,
                    new { profileId = previous.ProfileId });
            }

            AppManager.Instance.Reset();
            var restartStage = "preflight";
            try
            {
                return await CoreRestartFlow.ExecuteAsync(
                    () => BuildAndValidateCoreLaunchAsync(profile),
                    async () =>
                    {
                        restartStage = "stop";
                        SetCoreRuntime(previous with { State = CoreRuntimeState.Restarting, LastFailure = null });
                        await StopCoreMonitorAsync();
                        await StopCoreAndConfirmAsync(cancellationToken);
                    },
                    () =>
                    {
                        SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
                        restartStage = "start";
                    },
                    preflight => LaunchPreflightedCoreLockedAsync(preflight, cancellationToken));
            }
            catch (Exception exception)
            {
                var processIds = GetActiveCoreProcessIds();
                if (restartStage != "preflight")
                {
                    SetCoreRuntime(CurrentCoreRuntime with
                    {
                        State = CoreRuntimeState.Faulted,
                        ProcessIds = processIds,
                        LastFailure = exception.Message,
                    });
                }
                AddLog("core", $"Core restart failed during {restartStage}: {exception}");
                return restartStage == "stop"
                    ? OperationView.Fail("core_stop_failed", ApiMessageKeys.CoreStopFailed,
                        new { detail = exception.Message, processIds })
                    : OperationView.Fail("core_restart_failed", ApiMessageKeys.CoreStartFailed,
                        new { stage = restartStage, detail = exception.Message, processIds });
            }
    }

    public async Task<OperationView> StartLatencyTestAsync(string profileId)
    {
        var profile = await AppManager.Instance.GetProfileItem(profileId);
        if (profile is null || profile.IsComplex() || profile.Port <= 0)
        {
            return OperationView.Fail("speedtest_invalid_profile", ApiMessageKeys.SpeedTestInvalidProfile);
        }

        return await StartSpeedTestAsync(new SpeedTestRequest(ESpeedActionType.Tcping, [profileId]), CancellationToken.None);
    }

    public OperationView StopLatencyTests()
    {
        _speedtestService?.ExitLoop();
        return OperationView.Ok(ApiMessageKeys.CommonCompleted);
    }

    public IReadOnlyList<LogView> GetRecentLogs(int limit, string? filter = null) => _logs.Recent(limit, filter);
    public LogTailView GetLogTail(long afterSequence, int limit) => _logs.Tail(afterSequence, limit);

    public LogPageView GetRecentLogsPage(int page, int pageSize, string? filter = null) => _logs.RecentPage(page, pageSize, filter);

    public long ClearLogs()
    {
        var generation = _logs.Clear();
        _events.Publish("logs-cleared", new { generation });
        return generation;
    }

    private async Task OnCoreMessageAsync(bool notify, string message)
    {
        AddLog("core", message);
        await Task.CompletedTask;
    }

    private void AddLog(string source, string message)
    {
        foreach (var line in message.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if (!CoreLogPolicy.ShouldKeep(source, line)) continue;
            var entry = _logs.Add(source, line);
            _events.Publish("log", entry);
            Console.Out.WriteLine($"[{source}] {line}");
        }
    }

    private static void ConfigureServiceLibConsoleLogging()
    {
        var logging = LogManager.Configuration;
        if (logging is null)
        {
            return;
        }

        var target = new ConsoleTarget("web-console")
        {
            Layout = "${longdate}|${level:uppercase=true}|${logger}|${message}",
        };
        logging.AddTarget(target);
        logging.LoggingRules.Add(new LoggingRule("*", NLog.LogLevel.Debug, target));
        LogManager.Configuration = logging;
    }

    private Task OnStatisticsUpdateAsync(ServerSpeedItem update)
    {
        if (CurrentCoreRuntime.State != CoreRuntimeState.Running) return Task.CompletedTask;
        _trafficWindow.Add(update, DateTimeOffset.UtcNow);
        _events.Publish("traffic", update);
        return Task.CompletedTask;
    }

    // The subscription update owns the mutation gate while calling this helper.
    private async Task UpdateSubscriptionTimestampLockedAsync(string subscriptionId)
    {
        var updateTime = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (subscriptionId.Length > 0)
        {
            var item = await AppManager.Instance.GetSubItem(subscriptionId);
            if (item is not null)
            {
                item.UpdateTime = updateTime;
                if (await ConfigHandler.AddSubItem(Config, item) != 0)
                {
                    throw new IOException("ServiceLib could not save the subscription timestamp.");
                }
            }
            return;
        }

        foreach (var item in await AppManager.Instance.SubItems() ?? [])
        {
            if (item.Enabled)
            {
                item.UpdateTime = updateTime;
                if (await ConfigHandler.AddSubItem(Config, item) != 0)
                {
                    throw new IOException("ServiceLib could not save the subscription timestamp.");
                }
            }
        }
    }

    internal static bool TryValidateSubscription(SubscriptionInput input, out string code, out string messageKey)
    {
        if (string.IsNullOrWhiteSpace(input.Remarks))
        {
            code = "subscription_name_required";
            messageKey = ApiMessageKeys.SubscriptionNameRequired;
            return false;
        }
        if (!string.IsNullOrWhiteSpace(input.Url)
            && (!Uri.TryCreate(input.Url, UriKind.Absolute, out var uri)
                || uri.Scheme is not ("http" or "https")))
        {
            code = "subscription_url_invalid";
            messageKey = ApiMessageKeys.SubscriptionInvalidUrl;
            return false;
        }
        if (!HttpRequestHeadersHelper.TryParse(input.RequestHeaders, out _))
        {
            code = "subscription_headers_invalid";
            messageKey = ApiMessageKeys.CommonInvalidInput;
            return false;
        }

        code = "ok";
        messageKey = string.Empty;
        return true;
    }

    internal static SubItem ToSubItem(SubscriptionInput input, SubItem? existing) => new()
    {
        Id = existing?.Id ?? string.Empty,
        Remarks = input.Remarks.Trim(),
        Url = input.Url?.Trim() ?? string.Empty,
        MoreUrl = input.MoreUrl?.Trim() ?? existing?.MoreUrl ?? string.Empty,
        Enabled = input.Enabled ?? existing?.Enabled ?? true,
        UserAgent = input.UserAgent?.Trim() ?? existing?.UserAgent ?? string.Empty,
        RequestHeaders = input.RequestHeaders ?? existing?.RequestHeaders,
        Filter = input.Filter ?? existing?.Filter,
        AutoUpdateInterval = Math.Max(input.AutoUpdateInterval ?? existing?.AutoUpdateInterval ?? 0, 0),
        ConvertTarget = input.ConvertTarget ?? existing?.ConvertTarget,
        Memo = input.Memo ?? existing?.Memo,
        Sort = input.Sort ?? existing?.Sort ?? 0,
        UpdateTime = existing?.UpdateTime ?? 0,
        PrevProfile = input.PrevProfile ?? existing?.PrevProfile,
        NextProfile = input.NextProfile ?? existing?.NextProfile,
        PreSocksPort = input.PreSocksPort,
        CustomCoreType = input.CustomCoreType,
    };

    internal static SubscriptionView ToSubscriptionView(SubItem item) => new(
        item.Id,
        item.Remarks,
        item.Url,
        item.Enabled,
        item.MoreUrl,
        item.Filter,
        item.AutoUpdateInterval,
        item.UpdateTime,
        item.UserAgent,
        item.RequestHeaders,
        item.ConvertTarget,
        item.Memo,
        item.Sort,
        item.PrevProfile,
        item.NextProfile,
        item.PreSocksPort,
        item.CustomCoreType is null ? null : System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(item.CustomCoreType.Value.ToString()));

    private static void EnsureInboundDefaults(Config config)
    {
        if (config.Inbound.Count == 0)
        {
            config.Inbound.Add(new InItem
            {
                Protocol = nameof(EInboundProtocol.socks),
                LocalPort = 10808,
                UdpEnabled = true,
                SniffingEnabled = true,
            });
        }

        if (config.Inbound[0].LocalPort is <= 0 or > 65535)
        {
            config.Inbound[0].LocalPort = 10808;
        }
    }

    private RuntimeListenerSnapshot[] GetConfiguredListenerSnapshots()
    {
        var inbound = Config.Inbound.FirstOrDefault();
        if (inbound is null || inbound.LocalPort is <= 0 or > 65535)
        {
            return [];
        }

        var listeners = new List<RuntimeListenerSnapshot>();
        string[] localProtocols = inbound.UdpEnabled ? ["http", "socks", "udp"] : ["http", "socks"];
        var localAddress = inbound.AllowLANConn && !inbound.NewPort4LAN ? "0.0.0.0" : "127.0.0.1";
        listeners.Add(new RuntimeListenerSnapshot("local", localProtocols, localAddress, inbound.LocalPort));
        if (inbound.SecondLocalPortEnabled)
        {
            var secondaryPort = AppManager.Instance.GetLocalPort(EInboundProtocol.socks2);
            if (secondaryPort is > 0 and <= 65535)
            {
                listeners.Add(new RuntimeListenerSnapshot("local-secondary", localProtocols, "127.0.0.1", secondaryPort));
            }
        }
        if (inbound.AllowLANConn && inbound.NewPort4LAN)
        {
            var lanPort = AppManager.Instance.GetLocalPort(EInboundProtocol.socks3);
            if (lanPort is > 0 and <= 65535)
            {
                listeners.Add(new RuntimeListenerSnapshot("lan", localProtocols, "0.0.0.0", lanPort));
            }
        }
        return listeners.ToArray();
    }

    private static string[] GetExpectedCoreExecutablePaths(CoreConfigContextBuilderAllResult built)
    {
        var coreTypes = new ECoreType?[]
            {
                built.MainResult.Context.RunCoreType,
                built.PreSocksResult?.Context.RunCoreType,
            }
            .Where(coreType => coreType.HasValue)
            .Select(coreType => coreType!.Value)
            .Distinct();

        return coreTypes
            .Select(coreType => CoreInfoManager.Instance.GetCoreInfo(coreType))
            .Select(info => info is null ? string.Empty : CoreInfoManager.Instance.GetCoreExecFile(info, out _))
            .Where(path => !string.IsNullOrWhiteSpace(path) && File.Exists(path))
            .Select(Path.GetFullPath)
            .Distinct(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal)
            .ToArray();
    }

    private static string[] GetExpectedCoreConfigPaths(CoreConfigContextBuilderAllResult built)
    {
        var fileNames = built.PreSocksResult is null
            ? new[] { Global.CoreConfigFileName }
            : new[] { Global.CoreConfigFileName, Global.CorePreConfigFileName };
        return fileNames
            .Select(Utils.GetBinConfigPath)
            .Select(Path.GetFullPath)
            .Distinct(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal)
            .ToArray();
    }

    private static string? FindXrayExecutable(out string message)
    {
        var info = CoreInfoManager.Instance.GetCoreInfo(ECoreType.Xray);
        foreach (var name in info?.CoreExes ?? [])
        {
            var path = Utils.GetBinPath(Utils.GetExeName(name), ECoreType.Xray.ToString());
            if (File.Exists(path))
            {
                message = string.Empty;
                return path;
            }
        }

        message = $"Xray-core executable was not found under {Utils.GetBinPath(string.Empty, ECoreType.Xray.ToString())}.";
        return null;
    }

    private static async Task<bool> WaitForListenerAsync(int port, CancellationToken cancellationToken)
    {
        if (port is <= 0 or > 65535)
        {
            return false;
        }

        var deadline = DateTimeOffset.UtcNow.AddSeconds(3);
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (await IsListeningAsync(port, cancellationToken))
            {
                return true;
            }
            await Task.Delay(100, cancellationToken);
        }

        return false;
    }

    private static async Task<bool> IsListeningAsync(int port, CancellationToken cancellationToken)
    {
        try
        {
            using var client = new TcpClient();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromMilliseconds(250));
            await client.ConnectAsync("127.0.0.1", port, timeout.Token);
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return false;
        }
    }

    private async Task<IWebProxy?> GetRegionalPresetProxyAsync(CancellationToken cancellationToken)
    {
        var runtime = CurrentCoreRuntime;
        var inbound = Config.Inbound.FirstOrDefault();
        if (runtime.State != CoreRuntimeState.Running
            || !HasTrackedCoreProcesses
            || runtime.ProxyPort is not int port
            || inbound is null
            || port != inbound.LocalPort
            || !runtime.Listeners.Any(listener => listener.Name == "local"
                && listener.Port == port
                && listener.Protocols.Contains("socks", StringComparer.OrdinalIgnoreCase)))
        {
            return null;
        }

        // IsListeningAsync has a 250 ms connect budget. If the live mixed listener is not
        // already present, do not probe a configured-but-stopped SOCKS port via DownloadService.
        if (!await IsListeningAsync(port, cancellationToken)
            || !ReferenceEquals(runtime, CurrentCoreRuntime))
        {
            return null;
        }

        return new WebProxy($"socks5://{Global.Loopback}:{port}");
    }

    internal static async Task<bool> IsProjectedListenerUnavailableAsync(
        RuntimeListenerSnapshot target,
        IReadOnlyCollection<RuntimeListenerSnapshot> runtimeOwned,
        CancellationToken cancellationToken)
    {
        foreach (var address in GetProbeAddresses(target.ListenAddress))
        {
            var ownsTcp = runtimeOwned.Any(listener => listener.Port == target.Port
                && ListenerOwnsAddress(listener.ListenAddress, address));
            if (!ownsTcp
                && (await IsListeningOnAddressAsync(address, target.Port, cancellationToken)
                    || !CanBind(address, target.Port, SocketType.Stream, ProtocolType.Tcp)))
            {
                return true;
            }
            var targetUsesUdp = target.Protocols.Contains("udp", StringComparer.OrdinalIgnoreCase);
            var ownsUdp = runtimeOwned.Any(listener => listener.Port == target.Port
                && listener.Protocols.Contains("udp", StringComparer.OrdinalIgnoreCase)
                && ListenerOwnsAddress(listener.ListenAddress, address));
            if (targetUsesUdp && !ownsUdp
                && !CanBind(address, target.Port, SocketType.Dgram, ProtocolType.Udp))
            {
                return true;
            }
        }
        return false;
    }

    private static IPAddress[] GetProbeAddresses(string listenAddress)
    {
        if (IPAddress.TryParse(listenAddress, out var explicitAddress)
            && !explicitAddress.Equals(IPAddress.Any))
        {
            return [explicitAddress];
        }

        var addresses = new HashSet<IPAddress> { IPAddress.Loopback };
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up) continue;
            foreach (var address in network.GetIPProperties().UnicastAddresses
                         .Select(item => item.Address)
                         .Where(address => address.AddressFamily == AddressFamily.InterNetwork))
            {
                addresses.Add(address);
            }
        }
        return addresses.ToArray();
    }

    private static bool ListenerOwnsAddress(string listenAddress, IPAddress address) =>
        IPAddress.TryParse(listenAddress, out var parsed)
        && (parsed.Equals(IPAddress.Any) || parsed.Equals(address));

    private static async Task<bool> IsListeningOnAddressAsync(IPAddress address, int port, CancellationToken cancellationToken)
    {
        try
        {
            using var client = new TcpClient(address.AddressFamily);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromMilliseconds(250));
            await client.ConnectAsync(address, port, timeout.Token);
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return false;
        }
    }

    private static bool CanBind(IPAddress address, int port, SocketType socketType, ProtocolType protocolType)
    {
        try
        {
            using var socket = new Socket(address.AddressFamily, socketType, protocolType)
            {
                ExclusiveAddressUse = true,
            };
            socket.Bind(new IPEndPoint(address, port));
            if (socketType == SocketType.Stream) socket.Listen(1);
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

}
