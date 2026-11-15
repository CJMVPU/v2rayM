using V2rayM.Domain.Runtime;

namespace V2rayM.Application.Settings;

public sealed record SettingsRuntimeState(CoreRuntimeState State, bool HasActiveChild, bool OriginalStillRunning = false);
public sealed record RuntimeCommandResult(bool Success, string Code);
public sealed record SettingsRollbackResult(bool RolledBack, bool OldRuntimeRestored, bool ConfigRestored, string? Detail);

public interface ISettingsRecoveryRuntime
{
    SettingsRuntimeState Current { get; }
    Task RestoreConfigurationAsync();
    Task<RuntimeCommandResult> StopAsync();
    Task<RuntimeCommandResult> StartPreviousAsync();
    void SetStopped();
    void SetFaulted(string detail);
    void Log(string message);
}

public sealed class SettingsRecoveryService
{
    // Recovery intentionally does not take the failed/cancelled request's token.
    // The caller retains the lifecycle lease until compensation has completed.
    public async Task<SettingsRollbackResult> RestoreAsync(ISettingsRecoveryRuntime runtime, bool hadActiveChild,
        string failureCode, Func<Task>? beforeRuntimeRestore = null)
    {
        var configRestored = false;
        Exception? additionalFailure = null;
        if (beforeRuntimeRestore is not null)
        {
            try { await beforeRuntimeRestore(); }
            catch (Exception exception)
            {
                additionalFailure = exception;
                ApplicationDiagnostics.Report(runtime.Log, $"Additional state rollback failed before Core recovery ({failureCode}): {exception}");
            }
        }
        try
        {
            await runtime.RestoreConfigurationAsync();
            configRestored = true;
            var current = runtime.Current;
            if (hadActiveChild && current.State == CoreRuntimeState.Running && current.HasActiveChild && current.OriginalStillRunning)
            {
                ApplicationDiagnostics.Report(runtime.Log, $"Core settings were restored; the original Core remained healthy ({failureCode}).");
                return new(additionalFailure is null, true, true, additionalFailure?.Message);
            }
            if (current.HasActiveChild || current.State != CoreRuntimeState.Stopped)
            {
                var stop = await runtime.StopAsync();
                if (!stop.Success) throw new InvalidOperationException($"Could not stop the failed Core before rollback: {stop.Code}.");
            }
            if (additionalFailure is not null)
            {
                runtime.SetFaulted($"Settings rollback failed ({failureCode}); additional state rollback failed: {additionalFailure.Message}");
                return new(false, false, true, additionalFailure.Message);
            }
            if (!hadActiveChild)
            {
                runtime.SetStopped();
                ApplicationDiagnostics.Report(runtime.Log, $"Core settings apply failed ({failureCode}); the original stopped runtime intent was restored.");
                return new(true, true, true, null);
            }
            var restored = await runtime.StartPreviousAsync();
            if (!restored.Success) throw new InvalidOperationException($"The previous Core runtime could not be restored ({restored.Code}).");
            ApplicationDiagnostics.Report(runtime.Log, $"Core settings apply failed ({failureCode}); the previous configuration and Core runtime were restored.");
            return new(true, true, true, null);
        }
        catch (Exception exception)
        {
            runtime.SetFaulted($"Settings apply failed ({failureCode}); rollback failed: {exception.Message}");
            ApplicationDiagnostics.Report(runtime.Log, $"Settings rollback failed after {failureCode}: {exception}");
            return new(false, false, configRestored, exception.Message);
        }
    }
}
