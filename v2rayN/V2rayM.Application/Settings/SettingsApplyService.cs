using V2rayM.Domain.Runtime;

namespace V2rayM.Application.Settings;

public interface ISettingsApplyRuntime
{
    SettingsRuntimeState Current { get; }
    Task<RuntimeCommandResult> RestartAsync();
    void SetStopped();
    void Log(string message);
}
public sealed record SettingsApplyResult(bool Success, bool Restarted = false, string? FailureCode = null,
    SettingsRollbackResult? Rollback = null);

public sealed class SettingsApplyService
{
    public async Task<SettingsApplyResult> CompleteAsync(ISettingsApplyRuntime runtime, string section, bool changed,
        Func<string, Task<SettingsRollbackResult>> rollback)
    {
        var current = runtime.Current;
        var action = CoreSettingsApplyPolicy.Decide(current.State, current.HasActiveChild, changed);
        if (action is CoreSettingsApplyAction.Busy or CoreSettingsApplyAction.Inconsistent)
        {
            var code = action == CoreSettingsApplyAction.Busy ? "core_runtime_busy" : "core_runtime_faulted";
            return new(false, FailureCode: code, Rollback: await rollback(code));
        }
        if (action == CoreSettingsApplyAction.SaveOnly)
        {
            if (current.State == CoreRuntimeState.Faulted) runtime.SetStopped();
            return new(true);
        }
        RuntimeCommandResult result;
        try { result = await runtime.RestartAsync(); }
        catch (Exception exception)
        {
            // A process adapter can throw before producing a structured failure.
            // Persisted settings still require compensation in that case.
            ApplicationDiagnostics.Report(runtime.Log, $"Settings for {section} threw during Core restart: {exception}");
            const string code = "core_restart_failed";
            return new(false, FailureCode: code, Rollback: await rollback(code));
        }
        if (result.Success) return new(true, Restarted: true);
        ApplicationDiagnostics.Report(runtime.Log, $"Settings for {section} failed to apply: {result.Code}");
        return new(false, FailureCode: result.Code, Rollback: await rollback(result.Code));
    }
}
