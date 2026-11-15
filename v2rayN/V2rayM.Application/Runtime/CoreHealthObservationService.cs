using V2rayM.Domain.Runtime;

namespace V2rayM.Application.Runtime;

public interface ICoreHealthPublication<TSnapshot>
{
    // Comparison and publication must be atomic with command transitions.
    bool TryMarkFaulted(TSnapshot expected, CoreHealthFailure failure);
}

public sealed record CoreHealthObservation(bool Running, bool PublishedFailure);

public sealed class CoreHealthObservationService<TSnapshot>(ICoreHealthPublication<TSnapshot> publication)
{
    public CoreHealthObservation Observe(TSnapshot captured, CoreHealthEvidence evidence, CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        var published = evidence.Failure is { } failure && publication.TryMarkFaulted(captured, failure);
        return new(evidence.Running, published);
    }
}
