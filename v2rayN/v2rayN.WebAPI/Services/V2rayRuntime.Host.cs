using ServiceLib.Handler;
using ServiceLib.Helper;
using ServiceLib.Manager;
using V2rayM.Application.Runtime;
using V2rayM.Domain.Runtime;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    public Task InitializeAsync(CancellationToken cancellationToken, bool suppressCoreAutostart = false) =>
        new RuntimeStartupService(new HostStartupAdapter(this)).InitializeAsync(cancellationToken, suppressCoreAutostart);

    public async Task ShutdownAsync(CancellationToken cancellationToken) =>
        _ = await new RuntimeShutdownService(new HostShutdownAdapter(this)).ShutdownAsync(cancellationToken);

    private async Task<StartupProfileSelection> PrepareStartupConfigurationAsync()
    {
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
        await ConfigDbHandler.InitBuiltinDNS(Config);
        await BuiltinDnsProfileBootstrap.EnsureAsync(
            Config,
            async () => await ConfigDbQuery.DNSItems() ?? [],
            ConfigDbHandler.SaveDNSItems);
        await ConfigDbHandler.InitBuiltinFullConfigTemplate(Config);
        // Keep startup aligned with Desktop's StatusBarViewModel. In particular,
        // InitBuiltinRouting owns the RoutingIndexId -> IsActive migration and must
        // run even when a restored Desktop database already has routing rows.
        await ConfigDbHandler.InitBuiltinRouting(Config);
        _ = await ConfigDbHandler.GetDefaultRouting(Config);
        var restoredSubscriptions = await ConfigDbQuery.SubItems() ?? [];
        var normalizedSubIndexId = NormalizeSelectedSubscriptionId(
            Config.SubIndexId,
            restoredSubscriptions.Select(item => item.Id).ToArray());
        if (Config.SubIndexId != normalizedSubIndexId)
        {
            AddLog("restore", "The selected subscription group no longer exists; normalized the selection to all profiles.");
            Config.SubIndexId = normalizedSubIndexId;
        }
        var selectedProfileId = Config.IndexId;
        var defaultProfile = await ConfigTextHandler.GetDefaultServer(Config);
        await _mutations.RunAsync(() => EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync()));
        return new(selectedProfileId, defaultProfile?.IndexId);
    }

    private async Task InitializeStartupServicesAsync()
    {
        await ProfileExManager.Instance.Init();
        await CertPemManager.Instance.Init(Config);
        // The native macOS host routes TUN launches through its signed XPC helper.
        if (OperatingSystem.IsMacOS()) CoreManager.Instance.PrivilegedCoreLauncher = _macTunLauncher;
        await CoreManager.Instance.Init(Config, OnCoreMessageAsync);
        if (Config.GuiItem.EnableStatistics || Config.GuiItem.DisplayRealTimeSpeed)
        {
            await StatisticsManager.Instance.Init(Config, OnStatisticsUpdateAsync, GetStatisticsPort);
        }
        _xrayPath = FindXrayExecutable(out var missingXrayMessage);
        if (_xrayPath is null)
        {
            AddLog("core", missingXrayMessage);
        }

    }

    private sealed class HostStartupAdapter(V2rayRuntime owner) : IRuntimeStartup
    {
        public bool AutoStartConfigured => owner._configuration.GetValue("V2RAYN_WEB_AUTOSTART", false);
        public Task<RuntimeRestartIntent?> LoadRestoreIntentAsync(CancellationToken token) => LoadRestoreRuntimeStateAsync(token);
        public Task<RuntimeRestartIntent?> LoadUpdateIntentAsync(CancellationToken token) => LoadRuntimeRestartIntentAsync(WebUpdateRuntimeStatePath, token);
        public void LoadConfiguration()
        {
            if (!AppManager.Instance.InitApp()) throw new InvalidOperationException("ServiceLib could not load its configuration.");
        }
        public Task RecoverPendingConfigurationAsync() => owner._configStore.RecoverPendingRestoreAsync();
        public void InitializeComponents()
        {
            ConfigureServiceLibConsoleLogging();
            if (!AppManager.Instance.InitComponents()) throw new InvalidOperationException("ServiceLib component initialization failed.");
        }
        public Task<StartupProfileSelection> PrepareConfigurationAsync() => owner.PrepareStartupConfigurationAsync();
        public Task InitializeServicesAsync() => owner.InitializeStartupServicesAsync();
        public void MarkReady() { owner._initialized = true; owner.AddLog("web", "serviceLib.initialized"); }
        public void StartScheduledOperations(CancellationToken token) => owner.StartScheduledOperations(token);
        public async Task<bool> ProfileExistsAsync(string id, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            return await ConfigDbQuery.GetProfileItem(id) is not null;
        }
        public async Task<RuntimeStartResult> StartCoreAsync(string? id, CancellationToken token)
        {
            var result = await owner.StartCoreAsync(id, token);
            return new(result.Success, result.Code, result.MessageKey);
        }
        public Task CommitRestoreIntentAsync() => CommitRestoreRuntimeStateAsync();
        public void Log(string source, string message) => owner.AddLog(source, message);
    }

    private sealed class HostShutdownAdapter(V2rayRuntime owner) : IRuntimeShutdown
    {
        public bool ShouldSaveState => owner._initialized && !owner._restoring;
        public Task WaitForRestoreShutdownRequestAsync(CancellationToken token) => owner.WaitForRestoreShutdownRequestAsync(token);
        public Task<bool> StopSchedulesAsync(CancellationToken token) => owner.StopScheduledOperationsAsync(token);
        public Task<bool> DrainOperationsAsync(CancellationToken token, TimeSpan remaining) => owner._operations.StopAndDrainAsync(token, remaining);
        public Task SaveStatisticsAsync() => StatisticsManager.Instance.SaveTo();
        public async Task StopCoreAsync(CancellationToken token)
        {
            try
            {
                await owner.StopCoreMonitorAsync();
                await owner.StopCoreAndConfirmAsync(token);
                owner.SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
            }
            catch (Exception exception)
            {
                owner.SetCoreRuntime(owner.CurrentCoreRuntime with
                {
                    State = CoreRuntimeState.Faulted,
                    ProcessIds = owner.GetActiveCoreProcessIds(),
                    LastFailure = exception.Message,
                });
                throw;
            }
        }
        public Task SaveProfilesAsync() => ProfileExManager.Instance.SaveTo();
        public Task CloseStatisticsAsync() => StatisticsManager.Instance.CloseAsync();
        public Task SaveConfigurationAsync(CancellationToken token) => owner._mutations.RunAsync(
            () => EnsureConfigSaveSucceededAsync(() => owner._configStore.SaveAsync()), token);
        public Task CloseDatabaseAsync() => SQLiteHelper.Instance.DisposeDbConnectionAsync();
        public void Log(string message) => owner.AddLog("web", message);
        public void SetStage(string? stage) => ShutdownDiagnostics.SetStage(stage);
    }
}
