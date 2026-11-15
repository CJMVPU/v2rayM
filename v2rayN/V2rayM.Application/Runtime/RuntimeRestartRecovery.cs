using V2rayM.Domain.Runtime;

namespace V2rayM.Application.Runtime;

public sealed record RuntimeStartResult(bool Success, string Code, string? Detail = null);

public enum RuntimeRestartRecoverySource
{
    NotRequested,
    PreferredProfile,
    SelectedProfile,
    DefaultProfile,
    NoProfile,
    StartFailed,
}

public sealed record RuntimeRestartRecoveryResult(
    RuntimeRestartRecoverySource Source,
    string? ProfileId = null,
    string? FailureCode = null);

public static class RuntimeRestartRecovery
{
    public static bool ShouldAutoStart(RuntimeRestartIntent? intent, bool configured, bool setupRequired = false) =>
        RuntimeStartupPolicy.ShouldAutoStart(intent, configured, setupRequired);
    public static bool ShouldRecoverCore(RuntimeRestartIntent? intent, bool setupRequired) =>
        RuntimeStartupPolicy.ShouldRecoverCore(intent, setupRequired);

    public static async Task<RuntimeRestartRecoveryResult> RecoverAsync(
        RuntimeRestartIntent intent,
        string? selectedProfileId,
        string? defaultProfileId,
        Func<string, CancellationToken, Task<bool>> profileExists,
        Func<string, CancellationToken, Task<RuntimeStartResult>> startCore,
        Action<string> log,
        CancellationToken cancellationToken)
    {
        if (!intent.WasRunning)
        {
            return new(RuntimeRestartRecoverySource.NotRequested);
        }

        var reason = string.IsNullOrWhiteSpace(intent.Reason) ? "Runtime restart" : intent.Reason;
        ApplicationDiagnostics.Report(log, $"{reason} requested Core runtime recovery.");
        var preferredId = Normalize(intent.PreferredProfileId);
        if (preferredId is not null && await profileExists(preferredId, cancellationToken))
        {
            return await StartAsync(preferredId, reason, RuntimeRestartRecoverySource.PreferredProfile, startCore, log, cancellationToken);
        }

        if (preferredId is not null)
        {
            ApplicationDiagnostics.Report(log, $"Previous profile {preferredId} no longer exists after {reason.ToLowerInvariant()}.");
        }

        var selectedId = Normalize(selectedProfileId);
        if (selectedId is not null && selectedId != preferredId)
        {
            if (await profileExists(selectedId, cancellationToken))
            {
                ApplicationDiagnostics.Report(log, $"Falling back to selected profile {selectedId}.");
                return await StartAsync(selectedId, reason, RuntimeRestartRecoverySource.SelectedProfile, startCore, log, cancellationToken);
            }

            ApplicationDiagnostics.Report(log, $"Selected profile {selectedId} does not exist after {reason.ToLowerInvariant()}.");
        }

        var fallbackId = Normalize(defaultProfileId);
        if (fallbackId is not null && fallbackId != preferredId && fallbackId != selectedId
            && await profileExists(fallbackId, cancellationToken))
        {
            ApplicationDiagnostics.Report(log, $"Falling back to the default profile {fallbackId}.");
            return await StartAsync(fallbackId, reason, RuntimeRestartRecoverySource.DefaultProfile, startCore, log, cancellationToken);
        }

        ApplicationDiagnostics.Report(log, $"{reason} requested Core runtime recovery, but no valid profile exists in the current configuration. Core remains stopped.");
        return new(RuntimeRestartRecoverySource.NoProfile);
    }

    private static async Task<RuntimeRestartRecoveryResult> StartAsync(
        string profileId,
        string reason,
        RuntimeRestartRecoverySource source,
        Func<string, CancellationToken, Task<RuntimeStartResult>> startCore,
        Action<string> log,
        CancellationToken cancellationToken)
    {
        var result = await startCore(profileId, cancellationToken);
        if (result.Success)
        {
            ApplicationDiagnostics.Report(log, $"Core runtime restored successfully using {profileId}.");
            return new(source, profileId);
        }

        ApplicationDiagnostics.Report(log, $"{reason} requested Core runtime recovery, but Core failed to start using {profileId} (code: {result.Code}). No further restart will be attempted.");
        return new(RuntimeRestartRecoverySource.StartFailed, profileId, result.Code);
    }

    private static string? Normalize(string? profileId) =>
        string.IsNullOrWhiteSpace(profileId) ? null : profileId;
}
