using V2rayM.Domain.Subscriptions;

namespace V2rayM.Application.Subscriptions;

public interface ISubscriptionRepository
{
    Task<IReadOnlyList<Subscription>> ListAsync();
    Task<Subscription?> FindAsync(string id);
    // Return the persisted readback, including an assigned identity, or null on rejection.
    Task<Subscription?> SaveAsync(Subscription subscription);
}

public interface ISubscriptionHeaders
{
    bool IsValid(string? headers);
}

public enum SubscriptionSaveStatus { Added, Saved, NotFound, Rejected, NameRequired, InvalidUrl, InvalidHeaders }
public sealed record SubscriptionSaveResult(SubscriptionSaveStatus Status, Subscription? Subscription = null);

/// Application use cases depend only on ports and domain values, never HTTP or upstream DTOs.
public sealed class SubscriptionService(ISubscriptionRepository repository, IMutationScope mutations,
    ISubscriptionHeaders headers)
{
    public Task<IReadOnlyList<Subscription>> ListAsync() => repository.ListAsync();

    public Task<SubscriptionSaveResult> SaveAsync(SubscriptionEdit edit, string? id = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var validation = Subscription.Validate(edit, headers.IsValid(edit.RequestHeaders));
        if (validation != SubscriptionValidation.Valid)
            return Task.FromResult(new SubscriptionSaveResult(validation switch
            {
                SubscriptionValidation.NameRequired => SubscriptionSaveStatus.NameRequired,
                SubscriptionValidation.InvalidUrl => SubscriptionSaveStatus.InvalidUrl,
                _ => SubscriptionSaveStatus.InvalidHeaders,
            }));
        return mutations.RunAsync(async () =>
        {
            var existing = id is null ? null : await repository.FindAsync(id);
            if (id is not null && existing is null) return new SubscriptionSaveResult(SubscriptionSaveStatus.NotFound);
            var updated = Subscription.Apply(edit, existing);
            var saved = await repository.SaveAsync(updated);
            return saved is null ? new SubscriptionSaveResult(SubscriptionSaveStatus.Rejected)
                : new SubscriptionSaveResult(id is null ? SubscriptionSaveStatus.Added : SubscriptionSaveStatus.Saved, saved);
        }, cancellationToken);
    }
}
