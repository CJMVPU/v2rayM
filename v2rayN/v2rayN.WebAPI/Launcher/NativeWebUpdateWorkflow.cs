using V2rayM.Application.Updates;
using V2rayM.Domain.Runtime;
namespace v2rayN.WebAPI.Launcher;

internal sealed record NativeWebUpdateTransactionResult(bool Success, bool RollbackSucceeded, string? Detail);

internal static class NativeWebUpdateWorkflow
{
    public static bool RuntimeIntentIsSatisfied(V2rayM.Domain.Runtime.RuntimeRestartIntent intent, WebHealthProbeResult health)
    {
        CoreRuntimeState? state = health.CoreState?.ToLowerInvariant() switch
        {
            "running" => CoreRuntimeState.Running,
            "stopped" => CoreRuntimeState.Stopped,
            _ => null,
        };
        return intent.IsSatisfied(state, (health.CoreProcessIds?.Count ?? 0) > 0, health.CoreProfileId);
    }

    public static async Task<NativeWebUpdateTransactionResult> ApplyAsync(
        Func<Task> installCandidateAsync,
        Func<Task<bool>> startCandidateAndVerifyHealthAsync,
        Func<Task> restorePreviousFilesAsync,
        Func<Task<bool>> startPreviousAndVerifyHealthAsync,
        Action<string> setPhase,
        Func<Task> cleanBackupsAsync)
    {
        var result = await new ApplicationReplacementService(new ReplacementAdapter(installCandidateAsync,
            startCandidateAndVerifyHealthAsync, restorePreviousFilesAsync, startPreviousAndVerifyHealthAsync,
            setPhase, cleanBackupsAsync)).ApplyAsync();
        return new(result.Success, result.RollbackSucceeded, result.Detail);
    }

    private sealed class ReplacementAdapter(Func<Task> install, Func<Task<bool>> startCandidate,
        Func<Task> restore, Func<Task<bool>> startPrevious, Action<string> phase, Func<Task> cleanup) : IApplicationReplacement
    {
        public Task InstallAsync() => install();
        public Task<bool> StartAndVerifyCandidateAsync() => startCandidate();
        public Task RestoreFilesAsync() => restore();
        public Task<bool> StartAndVerifyPreviousAsync() => startPrevious();
        public Task CleanupAsync() => cleanup();
        public void Publish(ApplicationReplacementPhase value) => phase(value switch
        {
            ApplicationReplacementPhase.Installing => "installing",
            ApplicationReplacementPhase.Restarting => "restarting",
            ApplicationReplacementPhase.VerifyingHealth => "verifying-health",
            ApplicationReplacementPhase.RollingBack => "rolling-back",
            _ => throw new ArgumentOutOfRangeException(nameof(value)),
        });
        public void Log(string message) => Console.Error.WriteLine(message);
    }
}
