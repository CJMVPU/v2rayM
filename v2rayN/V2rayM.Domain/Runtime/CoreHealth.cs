namespace V2rayM.Domain.Runtime;

public enum CoreHealthFailure { ProcessExited, ListenerUnavailable }

/// Listener occupancy alone is never proof that our Core is alive. Transitional
/// states are commands in progress, not failures that observations may overwrite.
public sealed record CoreHealthEvidence(CoreRuntimeState State, bool HasOwnedProcesses, bool ListenerAvailable)
{
    public bool Running => State == CoreRuntimeState.Running && HasOwnedProcesses && ListenerAvailable;
    public CoreHealthFailure? Failure => State != CoreRuntimeState.Running ? null
        : !HasOwnedProcesses ? CoreHealthFailure.ProcessExited
        : !ListenerAvailable ? CoreHealthFailure.ListenerUnavailable : null;
}
