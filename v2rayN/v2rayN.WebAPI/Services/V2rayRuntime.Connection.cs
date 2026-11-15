using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Entities;
using V2rayM.Application.Runtime;
using V2rayM.Domain.Runtime;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    public Task<OperationView> SelectProfileAsync(string profileId, CancellationToken token, bool connect = true) =>
        _coreLifecycle.ExecuteAsync(() => RunConnectionAsync(service => connect
            ? service.StartAsync(profileId, token, selectProfile: true)
            : service.SelectOnlyAsync(profileId)), token);

    public Task<OperationView> StartCoreAsync(string? profileId, CancellationToken token) =>
        _coreLifecycle.ExecuteAsync(() => RunConnectionAsync(service =>
            service.StartAsync(string.IsNullOrWhiteSpace(profileId) ? null : profileId, token)), token);

    private Task<OperationView> StartCoreLockedAsync(ProfileItem? profile, CancellationToken token, bool selectProfile = false) =>
        RunConnectionAsync(service => service.StartAsync(profile?.IndexId, token, selectProfile));

    public Task<OperationView> StopCoreAsync(CancellationToken token) =>
        _coreLifecycle.ExecuteAsync(() => StopCoreLockedAsync(token), token);
    private Task<OperationView> StopCoreLockedAsync(CancellationToken token) => RunConnectionAsync(service => service.StopAsync(token));
    public Task<OperationView> RestartCoreAsync(CancellationToken token) =>
        _coreLifecycle.ExecuteAsync(() => RestartCoreLockedAsync(token), token);
    private Task<OperationView> RestartCoreLockedAsync(CancellationToken token) => RunConnectionAsync(service => service.RestartAsync(token));

    private async Task<OperationView> RunConnectionAsync(Func<CoreConnectionService, Task<CoreConnectionResult>> operation)
    {
        var runtime = new CoreConnectionRuntime(this);
        var result = await operation(new CoreConnectionService(runtime));
        return result.Status switch
        {
            CoreConnectionStatus.Started => OperationView.Ok(ApiMessageKeys.CoreStarted, new { profileId = result.ProfileId, processIds = result.ProcessIds }),
            CoreConnectionStatus.Restarted => OperationView.Ok(ApiMessageKeys.CoreRestarted, new { profileId = result.ProfileId, processIds = result.ProcessIds }),
            CoreConnectionStatus.AlreadyRunning => OperationView.Ok(ApiMessageKeys.CoreStarted, new { profileId = result.ProfileId, alreadyRunning = true }),
            CoreConnectionStatus.Stopped => OperationView.Ok(ApiMessageKeys.CoreStopped),
            CoreConnectionStatus.SelectionSaved => OperationView.Ok(ApiMessageKeys.CommonCompleted),
            CoreConnectionStatus.SelectionRequiresStop => OperationView.Fail("core_selection_requires_stop", ApiMessageKeys.CommonInvalidInput),
            CoreConnectionStatus.ProfileMissing => OperationView.Fail("profile_not_found", ApiMessageKeys.ProfileNotFound, new { profileId = result.ProfileId }),
            CoreConnectionStatus.NoSelection => OperationView.Fail("profile_not_selected", ApiMessageKeys.ProfileNoneSelected),
            CoreConnectionStatus.NotRunning => OperationView.Fail("core_not_running", ApiMessageKeys.CoreNotRunning,
                new { runtimeState = result.Stage, processIds = result.ProcessIds }),
            CoreConnectionStatus.PreflightRejected => runtime.PreflightFailure ?? throw new InvalidOperationException("Missing preflight rejection."),
            CoreConnectionStatus.PortOccupied => OperationView.Fail("proxy_port_in_use", ApiMessageKeys.CorePortInUse, new { port = result.Port }),
            CoreConnectionStatus.StopFailed => OperationView.Fail("core_stop_failed", ApiMessageKeys.CoreStopFailed,
                new { detail = result.Detail, processIds = result.ProcessIds }),
            CoreConnectionStatus.StartFailed => OperationView.Fail("core_start_failed", ApiMessageKeys.CoreStartFailed,
                new { profileId = result.ProfileId, detail = result.Detail, processIds = result.ProcessIds }),
            CoreConnectionStatus.RestartFailed => OperationView.Fail("core_restart_failed", ApiMessageKeys.CoreStartFailed,
                new { stage = result.Stage, detail = result.Detail, processIds = result.ProcessIds }),
            _ => throw new InvalidOperationException("Unknown connection outcome."),
        };
    }

    // Narrow process/helper adapter. The application never receives upstream
    // configuration, a process handle, or authority to change helper launch policy.
    private sealed class CoreConnectionRuntime(V2rayRuntime owner) : ICoreConnectionRuntime
    {
        private ProfileItem? _resolvedProfile;
        public OperationView? PreflightFailure { get; private set; }
        public CoreConnectionState Current => new(owner.CurrentCoreRuntime.State,
            owner.CurrentCoreRuntime.ProfileId, owner.GetActiveCoreProcessIds());
        public async Task<CoreConnectionProfile?> ResolveProfileAsync(string? id)
        {
            _resolvedProfile = id is null ? await owner.GetDefaultProfileAsync()
                : await owner._mutations.RunAsync(() => AppManager.Instance.GetProfileItem(id));
            return _resolvedProfile is null ? null : new(_resolvedProfile.IndexId);
        }
        public Task SelectProfileAsync(string id) => owner._mutations.RunAsync(async () =>
        {
            var previous = owner.Config.IndexId;
            owner.Config.IndexId = id;
            try { await EnsureConfigSaveSucceededAsync(() => owner._configStore.SaveAsync()); }
            catch (Exception failure)
            {
                owner.Config.IndexId = previous;
                try { await EnsureConfigSaveSucceededAsync(() => owner._configStore.SaveAsync()); }
                catch (Exception restore) { throw new AggregateException("Node selection and its persistence recovery failed.", failure, restore); }
                throw;
            }
        });
        public void ResetConfigurationCache() => AppManager.Instance.Reset();
        public async Task<ICoreLaunchPlan?> PrepareAsync(CoreConnectionProfile profile)
        {
            if (_resolvedProfile?.IndexId != profile.Id) throw new InvalidOperationException("The launch candidate was not resolved under this lease.");
            var preflight = await owner.BuildAndValidateCoreLaunchAsync(_resolvedProfile);
            PreflightFailure = preflight.Failure;
            return preflight.Success ? new Plan(preflight, owner.Config.Inbound.FirstOrDefault()?.LocalPort ?? 0) : null;
        }
        public Task<bool> IsPortOccupiedAsync(ICoreLaunchPlan plan, CancellationToken token) => IsListeningAsync(plan.ProxyPort, token);
        public void SetTransition(CoreRuntimeState state) => owner.SetCoreRuntime(owner.CurrentCoreRuntime with { State = state, LastFailure = null });
        public void SetStopped() => owner.SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
        public void SetStarting(ICoreLaunchPlan plan)
        {
            var built = ((Plan)plan).Preflight.BuiltContext;
            var listeners = owner.GetConfiguredListenerSnapshots();
            owner.SetCoreRuntime(new(CoreRuntimeState.Starting, plan.ProfileId,
                built.PreSocksResult?.Context.RunCoreType ?? built.MainResult.Context.RunCoreType,
                null, listeners.FirstOrDefault(listener => listener.Name == "local")?.Port,
                AppManager.Instance.StatePort, listeners, [], null));
        }
        public void SetRunning() => owner.SetCoreRuntime(owner.CurrentCoreRuntime with
        {
            State = CoreRuntimeState.Running, CoreType = AppManager.Instance.RunningCoreType,
            StartedAt = DateTimeOffset.UtcNow, ProcessIds = owner.GetActiveCoreProcessIds(), LastFailure = null,
        });
        public void SetFaulted(string detail) => owner.SetCoreRuntime(owner.CurrentCoreRuntime with
        { State = CoreRuntimeState.Faulted, ProcessIds = owner.GetActiveCoreProcessIds(), LastFailure = detail });
        public Task StopMonitorAsync() => owner.StopCoreMonitorAsync();
        public Task StopAndConfirmAsync(CancellationToken token) => owner.StopCoreAndConfirmAsync(token);
        public async Task LaunchAsync(ICoreLaunchPlan plan)
        {
            var built = ((Plan)plan).Preflight.BuiltContext;
            var existing = CoreProcessTracker.CaptureExistingProcessIds();
            var executables = GetExpectedCoreExecutablePaths(built);
            var configs = GetExpectedCoreConfigPaths(built);
            try { await CoreManager.Instance.LoadCore(built.MainResult.Context, built.PreSocksResult?.Context); }
            finally
            {
                var tracked = OperatingSystem.IsMacOS()
                    ? CoreProcessTracker.CaptureOwnedProcesses(CoreManager.Instance.GetOwnedCoreProcessIds())
                    : CoreProcessTracker.CaptureStartedProcesses(existing, executables, configs);
                owner.SetTrackedCoreProcesses(tracked.Concat(owner._macTunLauncher.CaptureIdentities()));
            }
        }
        public Task<bool> WaitForListenerAsync(ICoreLaunchPlan plan, CancellationToken token) => V2rayRuntime.WaitForListenerAsync(plan.ProxyPort, token);
        public Task StartMonitorAsync() => owner.StartCoreMonitorAsync();
        public async Task PublishStatusAsync() => owner._events.Publish("status", await owner.GetStatusAsync());
        public void Log(string message) => owner.AddLog("core", message);
        private sealed record Plan(CoreLaunchPreflightResult Preflight, int ProxyPort) : ICoreLaunchPlan
        { public string ProfileId => Preflight.Profile.IndexId; }
    }
}
