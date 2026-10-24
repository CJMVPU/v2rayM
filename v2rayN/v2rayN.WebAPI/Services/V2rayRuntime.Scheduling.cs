using ServiceLib.Common;
using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Entities;
using ServiceLib.Services;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private CancellationTokenSource? _scheduledOperationsCancellation;
    private Task? _scheduledOperationsTask;

    private void StartScheduledOperations(CancellationToken hostToken)
    {
        _scheduledOperationsCancellation = CancellationTokenSource.CreateLinkedTokenSource(hostToken, _operations.ShutdownToken);
        var cancellationToken = _scheduledOperationsCancellation.Token;
        _scheduledOperationsTask = Task.Run(() => RunScheduledOperationsAsync(cancellationToken));
    }

    private async Task<bool> StopScheduledOperationsAsync(CancellationToken shutdownToken)
    {
        var cancellation = _scheduledOperationsCancellation;
        var task = _scheduledOperationsTask;
        if (cancellation is null || task is null)
        {
            return true;
        }

        cancellation.Cancel();
        try
        {
            await task.WaitAsync(shutdownToken);
        }
        catch (OperationCanceledException) when (task.IsCompleted && cancellation.IsCancellationRequested)
        {
            // Expected during graceful service shutdown.
        }
        finally
        {
            if (task.IsCompleted)
            {
                cancellation.Dispose();
                _scheduledOperationsCancellation = null;
                _scheduledOperationsTask = null;
            }
        }

        return true;
    }

    private async Task RunScheduledOperationsAsync(CancellationToken cancellationToken)
    {
        var elapsedMinutes = 1;
        while (true)
        {
            await Task.Delay(TimeSpan.FromMinutes(1), cancellationToken);
            await RunScheduledStepAsync("subscription", RunScheduledSubscriptionUpdatesAsync, cancellationToken);

            if (elapsedMinutes % 20 == 0)
            {
                await RunScheduledStepAsync("save", async token =>
                {
                    await using var operation = await _operations.EnterOperationAsync(token);
                    await _mutations.RunAsync(async () =>
                    {
                        await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
                        await ProfileExManager.Instance.SaveTo();
                    }, operation.Token);
                }, cancellationToken);
            }

            if (elapsedMinutes % 60 == 0)
            {
                await RunScheduledStepAsync("cleanup", async token =>
                {
                    await using var operation = await _operations.EnterOperationAsync(token);
                    FileUtils.DeleteExpiredFiles(Utils.GetBinConfigPath(), DateTime.Now.AddHours(-1), "Test");
                    FileUtils.DeleteExpiredFiles(Utils.GetLogPath(), DateTime.Now.AddDays(-7));
                    FileUtils.DeleteExpiredFiles(Utils.GetTempPath(), DateTime.Now.AddDays(-7));
                }, cancellationToken);

                var elapsedHours = elapsedMinutes / 60;
                if (Config.GuiItem.AutoUpdateInterval > 0 && elapsedHours % Config.GuiItem.AutoUpdateInterval == 0)
                {
                    await RunScheduledStepAsync("geo-update", RunScheduledGeoUpdateAsync, cancellationToken);
                }
            }

            if (elapsedMinutes % 1440 == 1)
            {
                await RunScheduledStepAsync("core-update-check", RunScheduledCoreUpdateCheckAsync, cancellationToken);
            }
            elapsedMinutes++;
        }
    }

    private async Task RunScheduledStepAsync(string name, Func<CancellationToken, Task> step, CancellationToken cancellationToken)
    {
        try
        {
            await step(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            AddLog("task", $"{name}: {exception.Message}");
        }
    }

    private async Task RunScheduledSubscriptionUpdatesAsync(CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        IReadOnlyList<SubItem> subscriptions;
        await using (var operation = await _operations.EnterOperationAsync(cancellationToken))
        {
            subscriptions = (await AppManager.Instance.SubItems() ?? [])
                .Where(item => item.AutoUpdateInterval > 0
                               && now - item.UpdateTime >= item.AutoUpdateInterval * 60L)
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

    private async Task RunScheduledCoreUpdateCheckAsync(CancellationToken cancellationToken)
    {
        await using var operation = await _operations.EnterOperationAsync(cancellationToken);
        var updateService = new UpdateService(Config, (_, _) => Task.CompletedTask);
        var messages = await updateService.CheckHasUpdateOnlyAll(
            Config.CheckUpdateItem.UpdateViaProxy,
            operation.Token);
        foreach (var message in messages)
        {
            AddLog("update", message);
        }
    }
}
