using ServiceLib.Manager;
using V2rayM.Application.Settings;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    // This private adapter binds application ports to locked lifecycle operations.
    // It cannot be used independently of the transaction owning the lifecycle gate.
    private sealed class CoreSettingsRuntimeAdapter(V2rayRuntime owner, CoreSettingsApplyContext? context = null)
        : ISettingsApplyRuntime, ISettingsRecoveryRuntime, ISettingsEditEffects
    {
        public SettingsRuntimeState Current
        {
            get
            {
                var current = owner.CurrentCoreRuntime;
                var original = context?.OldRuntime;
                var pids = owner.GetActiveCoreProcessIds();
                var same = original is not null && original.ProcessIds.Length > 0
                    && original.ProfileId == current.ProfileId && original.StartedAt == current.StartedAt
                    && original.ProcessIds.ToHashSet().SetEquals(pids);
                return new(current.State, pids.Length > 0, same);
            }
        }
        public Task RestoreConfigurationAsync() => owner._settingsTransaction.RestoreAsync(context
            ?? throw new InvalidOperationException("Recovery requires a captured settings transaction."));
        public async Task<RuntimeCommandResult> StopAsync()
        {
            var result = await owner.StopCoreLockedAsync(CancellationToken.None);
            return new(result.Success, result.Code);
        }
        public async Task<RuntimeCommandResult> RestartAsync()
        {
            var result = await owner.RestartCoreLockedAsync(CancellationToken.None);
            return new(result.Success, result.Code);
        }
        public async Task<RuntimeCommandResult> StartPreviousAsync()
        {
            if (context is null) throw new InvalidOperationException("Recovery requires a captured settings transaction.");
            await CoreManager.Instance.Init(owner.Config, owner.OnCoreMessageAsync);
            var id = context.OldRuntime.ProfileId ?? owner.Config.IndexId;
            var profile = await AppManager.Instance.GetProfileItem(id)
                ?? throw new InvalidOperationException($"The previous Core profile {id} no longer exists.");
            var result = await owner.StartCoreLockedAsync(profile, CancellationToken.None);
            return new(result.Success, result.Code);
        }
        public void SetStopped() => owner.SetCoreRuntime(CoreRuntimeSnapshot.Stopped);
        public void SetFaulted(string detail) => owner.SetCoreRuntime(owner.CurrentCoreRuntime with
        {
            State = V2rayM.Domain.Runtime.CoreRuntimeState.Faulted,
            ProcessIds = owner.GetActiveCoreProcessIds(),
            LastFailure = detail,
        });
        public async Task RefreshStatisticsAsync()
        {
            await StatisticsManager.Instance.CloseAsync();
            owner._trafficWindow.Clear();
            if (owner.Config.GuiItem.EnableStatistics || owner.Config.GuiItem.DisplayRealTimeSpeed)
                await StatisticsManager.Instance.Init(owner.Config, owner.OnStatisticsUpdateAsync);
        }
        public void Log(string message) => owner.AddLog("settings", message);
    }
}
