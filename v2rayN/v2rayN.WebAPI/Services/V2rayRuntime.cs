using V2rayM.Application.Runtime;
using v2rayN.WebAPI.Adapters.Settings;
using V2rayM.Application.Settings;
using V2rayM.Application.Routing;
using v2rayN.WebAPI.Adapters.Routing;
using V2rayM.Application.Diagnostics;
using v2rayN.WebAPI.Adapters.Diagnostics;
using V2rayM.Application.Profiles;
using v2rayN.WebAPI.Adapters.Profiles;
using v2rayN.WebAPI.Adapters.Subscriptions;
using V2rayM.Application.Subscriptions;
using V2rayM.Domain.Subscriptions;
using V2rayM.Domain.Runtime;
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
    private readonly SettingsApplyService _settingsApply = new();
    private readonly SettingsEditorService _settingsEditor;
    private readonly SettingsRecoveryService _settingsRecovery = new();
    private readonly ModuleUpdateCoordinator _moduleUpdates;
    private readonly SubscriptionService _subscriptions;
    private readonly ProfileCatalogService _profileCatalog;
    private readonly ProfileEditorService _profileEditor;
    private readonly ProfileQueryService _profileQueries;
    private readonly RoutingRuleService _routingRules;
    private readonly RoutingProfileService _routingProfiles;
    private readonly ProfileMaintenanceService _profileMaintenance;
    private readonly SpeedTestCoordinator _speedTests;
    private readonly ProfileRemovalService _profileRemoval;
    private readonly ProfileExportService _profileExport;
    private readonly SubscriptionUpdateService _subscriptionUpdates;
    private readonly SubscriptionRemovalService _subscriptionRemoval;
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
        _settingsEditor = new SettingsEditorService(new ServiceLibSettingsEditor(_configStore), _mutations,
            new SettingsEditValidator(SettingsCapabilities), new CoreSettingsRuntimeAdapter(this));
        _moduleUpdates = new ModuleUpdateCoordinator(_execution);
        _routingRules = new RoutingRuleService(new ServiceLibRoutingRules(), _mutations);
        _routingProfiles = new RoutingProfileService(new ServiceLibRoutingProfiles(() => Config,
            () => EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync())), _mutations);
        _profileQueries = new ProfileQueryService(new ServiceLibProfileQueries(() => Config));
        _profileMaintenance = new ProfileMaintenanceService(new ServiceLibProfileMaintenance(() => Config,
            () => CurrentCoreRuntime.ProfileId), _mutations, new ProfileCatalogEvents(events, message => AddLog("profile", message)));
        var speedTests = new ServiceLibSpeedTests(() => Config, events, message => AddLog("speedtest", message));
        _speedTests = new SpeedTestCoordinator(operations, _mutations, speedTests, speedTests);
        _profileEditor = new ProfileEditorService(new ServiceLibProfileEditor(() => Config,
            id => CurrentCoreRuntime.State == CoreRuntimeState.Running && CurrentCoreRuntime.ProfileId == id), _mutations,
            new ProfileCatalogEvents(events, message => AddLog("profile", message)));
        _profileRemoval = new ProfileRemovalService(new ServiceLibProfileRemoval(() => Config,
            () => (CurrentCoreRuntime.ProfileId, CurrentCoreRuntime.State == CoreRuntimeState.Running, HasTrackedCoreProcesses),
            () => EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync())), _mutations,
            new ProfileCatalogEvents(events, message => AddLog("profile", message)));
        _profileExport = new ProfileExportService(new ServiceLibProfileExport(() => Config), _mutations);
        _profileCatalog = new ProfileCatalogService(new ServiceLibProfileCatalog(() => Config,
            () => EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync())), _mutations,
            new ProfileCatalogEvents(events, message => AddLog("profile", message)));
        _subscriptions = new SubscriptionService(new ServiceLibSubscriptionRepository(() => Config),
            _mutations, new ServiceLibSubscriptionHeaders());
        _subscriptionUpdates = new SubscriptionUpdateService(operations, _mutations,
            new ServiceLibSubscriptionUpdater(() => Config, () => EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync())),
            new SubscriptionUpdateEvents(events, message => AddLog("subscription", message)), TimeProvider.System);
        _subscriptionRemoval = new SubscriptionRemovalService(
            new ServiceLibSubscriptionRemoval(() => Config, () => CurrentCoreRuntime.ProfileId,
                () => EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync())), _mutations);
    }
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

    internal static async Task EnsureConfigSaveSucceededAsync(Func<Task<int>> save)
    {
        if (await save() != 0)
        {
            throw new IOException("ServiceLib could not persist the configuration.");
        }
    }

    public async Task<IReadOnlyList<ProfileView>> GetProfilesAsync(string? subscriptionId, string? filter) =>
        (await _profileQueries.ListAsync(subscriptionId, filter)).Select(ProfileQueryContractMapper.ToView).ToArray();

    public Task<ProfileItem?> GetProfileDetailsAsync(string profileId) => ServiceLibProfileQueries.ReadDetailsAsync(profileId);

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
        var health = _coreLifecycle.ObserveHealth(snapshot, processIds, listening);
        var coreRunning = health.Running;
        if (health.PublishedFailure)
        {
            snapshot = snapshot with
            {
                State = CoreRuntimeState.Faulted,
                ProcessIds = processIds,
                LastFailure = CoreLifecycleService.FailureMessage(processIds.Length == 0
                    ? CoreHealthFailure.ProcessExited : CoreHealthFailure.ListenerUnavailable),
            };
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

    internal static OperationView? GetTunLaunchRejection(CoreConfigContextBuilderAllResult built) =>
        CoreLaunchPreflight.GetTunLaunchRejection(built);

    internal static string NormalizeSelectedSubscriptionId(string? selectedId, IReadOnlyCollection<string> availableIds) =>
        string.IsNullOrEmpty(selectedId) || availableIds.Contains(selectedId, StringComparer.Ordinal)
            ? selectedId ?? string.Empty
            : string.Empty;

    public Task<OperationView> StartLatencyTestAsync(string profileId) =>
        StartSpeedTestAsync(new SpeedTestRequest(ESpeedActionType.Tcping, [profileId]), CancellationToken.None, singleProfile: true);

    public OperationView StopLatencyTests()
    {
        _speedTests.Stop();
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

    private int GetStatisticsPort() => CurrentCoreRuntime.ApiPort ?? AppManager.Instance.StatePort;

    private Task OnStatisticsUpdateAsync(ServerSpeedItem update)
    {
        if (CurrentCoreRuntime.State != CoreRuntimeState.Running) return Task.CompletedTask;
        _trafficWindow.Add(update, DateTimeOffset.UtcNow);
        _events.Publish("traffic", update);
        return Task.CompletedTask;
    }



    internal static SubItem ToSubItem(SubscriptionInput input, SubItem? existing) =>
        ServiceLibSubscriptionRepository.ApplyToItem(Subscription.Apply(SubscriptionContractMapper.ToEdit(input),
            existing is null ? null : ServiceLibSubscriptionRepository.ToDomain(existing)), new SubItem());

    internal static SubscriptionView ToSubscriptionView(SubItem item) =>
        SubscriptionContractMapper.ToView(ServiceLibSubscriptionRepository.ToDomain(item));

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
