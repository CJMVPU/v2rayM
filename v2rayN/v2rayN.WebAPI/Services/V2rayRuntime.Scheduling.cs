using V2rayM.Application.Runtime;
using V2rayM.Domain.Runtime;
using ServiceLib.Common;
using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Entities;
using ServiceLib.Services;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private ScheduledMaintenanceService? _scheduledMaintenance;

    private void StartScheduledOperations(CancellationToken hostToken)
    {
        _scheduledMaintenance ??= new(new ScheduledMaintenanceAdapter(this));
        if (!_scheduledMaintenance.Start(hostToken, _operations.ShutdownToken))
            throw new InvalidOperationException("Scheduled maintenance is already owned by an active run.");
    }

    private Task<bool> StopScheduledOperationsAsync(CancellationToken shutdownToken) =>
        _scheduledMaintenance?.StopAsync(shutdownToken) ?? Task.FromResult(true);

    private sealed class ScheduledMaintenanceAdapter(V2rayRuntime owner) : IScheduledMaintenance
    {
        public int GeoUpdateIntervalHours => owner.Config.GuiItem.AutoUpdateInterval;
        public async Task ExecuteAsync(MaintenanceAction action, CancellationToken token)
        {
            switch (action)
            {
                case MaintenanceAction.Subscriptions:
                    await owner.RunScheduledSubscriptionUpdatesAsync(token);
                    break;
                case MaintenanceAction.SaveState:
                    await using (var operation = await owner._operations.EnterOperationAsync(token))
                    {
                        await owner._mutations.RunAsync(async () =>
                        {
                            await EnsureConfigSaveSucceededAsync(() => owner._configStore.SaveAsync());
                            await ProfileExManager.Instance.SaveTo();
                        }, operation.Token);
                    }
                    break;
                case MaintenanceAction.CleanupFiles:
                    await using (var operation = await owner._operations.EnterOperationAsync(token))
                    {
                        operation.Token.ThrowIfCancellationRequested();
                        FileUtils.DeleteExpiredFiles(Utils.GetBinConfigPath(), DateTime.Now.AddHours(-1), "Test");
                        FileUtils.DeleteExpiredFiles(Utils.GetLogPath(), DateTime.Now.AddDays(-7));
                        FileUtils.DeleteExpiredFiles(Utils.GetTempPath(), DateTime.Now.AddDays(-7));
                    }
                    break;
                case MaintenanceAction.GeoUpdate:
                    await owner.RunScheduledGeoUpdateAsync(token);
                    break;
                case MaintenanceAction.CoreUpdateCheck:
                    await owner.RunScheduledCoreUpdateCheckAsync(token);
                    break;
                default: throw new ArgumentOutOfRangeException(nameof(action));
            }
        }
        public void Log(MaintenanceAction action, string detail) => owner.AddLog("task", $"{action}: {detail}");
    }

    private async Task RunScheduledSubscriptionUpdatesAsync(CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        IReadOnlyList<V2rayM.Domain.Subscriptions.Subscription> subscriptions;
        await using (var operation = await _operations.EnterOperationAsync(cancellationToken))
        {
            subscriptions = (await _subscriptions.ListAsync())
                .Where(item => item.Enabled && item.IsUpdateDue(now) && _subscriptionUpdates.CanAutoUpdate(item.Id))
                .ToArray();
        }

        foreach (var subscription in subscriptions)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var update = StartSubscriptionUpdateTask(subscription.Id, useProxy: true, cancellationToken);
            if (update is not null)
            {
                await update.WaitAsync(cancellationToken);
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
            }
        }
    }

    private async Task RunScheduledGeoUpdateAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        // Use the same task registration, file transaction, platform selection and
        // serving-core reload/rollback as a manual update. Direct ServiceLib calls
        // bypass those guarantees and leave a privileged core on stale Geo snapshots.
        var started = StartGeoUpdate(Config.CheckUpdateItem.UpdateViaProxy
            && CurrentCoreRuntime.State == CoreRuntimeState.Running);
        if (!started.Success)
        {
            AddLog("task", $"Scheduled GeoFiles update skipped: {started.Code}");
            return;
        }
        Task? task;
        task = _moduleUpdates.GetTask("geo-update");
        if (task is not null) await task.WaitAsync(cancellationToken);
    }

    private Task RunScheduledCoreUpdateCheckAsync(CancellationToken cancellationToken) =>
        new V2rayM.Application.Updates.ScheduledUpdateCheckService(new ScheduledUpdateCheckAdapter(this)).RunAsync(cancellationToken);
}
