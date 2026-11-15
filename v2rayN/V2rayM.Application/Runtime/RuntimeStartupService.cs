using V2rayM.Domain.Runtime;

namespace V2rayM.Application.Runtime;

public sealed record StartupProfileSelection(string? SelectedId, string? DefaultId);

public interface IRuntimeStartup
{
    bool AutoStartConfigured { get; }
    Task<RuntimeRestartIntent?> LoadRestoreIntentAsync(CancellationToken token);
    Task<RuntimeRestartIntent?> LoadUpdateIntentAsync(CancellationToken token);
    void LoadConfiguration();
    Task RecoverPendingConfigurationAsync();
    void InitializeComponents();
    Task<StartupProfileSelection> PrepareConfigurationAsync();
    Task InitializeServicesAsync();
    void MarkReady();
    void StartScheduledOperations(CancellationToken token);
    Task<bool> ProfileExistsAsync(string id, CancellationToken token);
    Task<RuntimeStartResult> StartCoreAsync(string? id, CancellationToken token);
    Task CommitRestoreIntentAsync();
    void Log(string source, string message);
}

public sealed class RuntimeStartupService(IRuntimeStartup runtime)
{
    public async Task InitializeAsync(CancellationToken token, bool setupRequired)
    {
        var restore = await runtime.LoadRestoreIntentAsync(token);
        var intent = restore ?? await runtime.LoadUpdateIntentAsync(token);
        token.ThrowIfCancellationRequested();
        runtime.LoadConfiguration();
        // Recovery must precede components, background mutators and any launch.
        await runtime.RecoverPendingConfigurationAsync();
        token.ThrowIfCancellationRequested();
        runtime.InitializeComponents();
        var selection = await runtime.PrepareConfigurationAsync();
        token.ThrowIfCancellationRequested();
        await runtime.InitializeServicesAsync();
        runtime.MarkReady();
        token.ThrowIfCancellationRequested();

        if (intent is not null)
        {
            if (RuntimeStartupPolicy.ShouldRecoverCore(intent, setupRequired))
                await RuntimeRestartRecovery.RecoverAsync(intent, selection.SelectedId, selection.DefaultId,
                    runtime.ProfileExistsAsync, runtime.StartCoreAsync,
                    message => runtime.Log(restore is not null ? "restore" : "update", message), token);
            else if (setupRequired && intent.WasRunning)
                runtime.Log("core", "Core startup was suppressed until first-run Management Key setup is complete.");

            // Restore markers are consumed only after initialization/recovery.
            // Update markers belong to the external health verifier's commit.
            if (restore is not null) await runtime.CommitRestoreIntentAsync();
        }
        else if (RuntimeStartupPolicy.ShouldAutoStart(null, runtime.AutoStartConfigured, setupRequired))
        {
            var started = await runtime.StartCoreAsync(null, token);
            if (!started.Success) runtime.Log("core", started.Detail ?? started.Code);
        }
        else if (setupRequired)
            runtime.Log("core", "Core autostart was suppressed until first-run Management Key setup is complete.");

        // Recovery can take longer than the first scheduler interval. Do not
        // permit background mutations until the startup intention is resolved.
        token.ThrowIfCancellationRequested();
        runtime.StartScheduledOperations(token);
    }
}
