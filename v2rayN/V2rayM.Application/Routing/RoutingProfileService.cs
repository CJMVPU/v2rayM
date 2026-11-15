using V2rayM.Domain.Routing;

namespace V2rayM.Application.Routing;

// The adapter retains the complete upstream document. Only editable settings cross
// the boundary; identity, ordering and activation are controlled by the use case.
public interface IRoutingProfileDocument
{
    string Id { get; }
    bool Active { get; }
    int Sort { get; }
    RoutingProfileSettings Settings { get; }
    void Initialize(int sort);
    void Edit(RoutingProfileSettings settings);
}
public interface IRoutingProfileStore
{
    Task<IReadOnlyList<IRoutingProfileDocument>> ListAsync();
    Task<IRoutingProfileDocument?> FindAsync(string id);
    Task<bool> SaveAsync(IRoutingProfileDocument document);
    Task DeleteAsync(IRoutingProfileDocument document);
    Task<bool> ActivateAsync(IRoutingProfileDocument document);
    Task ClearSelectionAsync();
    Task<bool> ImportPresetsAsync();
}
public enum RoutingProfileStatus { Saved, NotFound, SaveFailed, ActivateFailed, ImportFailed }
public sealed record RoutingProfileResult(RoutingProfileStatus Status, string? Id = null, bool AffectsCore = false);

public sealed class RoutingProfileService(IRoutingProfileStore store, IMutationScope mutations)
{
    public Task<RoutingProfileResult> SaveAsync(IRoutingProfileDocument input, string? id = null) => mutations.RunAsync(async () =>
    {
        var creating = string.IsNullOrEmpty(id);
        var item = creating ? input : await store.FindAsync(id!);
        if (item is null) return new RoutingProfileResult(RoutingProfileStatus.NotFound);
        var before = item.Settings;
        if (creating)
            item.Initialize(RoutingProfilePolicy.NewSort(input.Sort, (await store.ListAsync()).Select(route => route.Sort)));
        else
            item.Edit(input.Settings);
        if (!await store.SaveAsync(item)) return new RoutingProfileResult(RoutingProfileStatus.SaveFailed);
        return new RoutingProfileResult(RoutingProfileStatus.Saved, item.Id, item.Active && before != item.Settings);
    });

    public Task<RoutingProfileResult> DeleteAsync(string id) => mutations.RunAsync(async () =>
    {
        var item = await store.FindAsync(id);
        if (item is null) return new RoutingProfileResult(RoutingProfileStatus.NotFound);
        await store.DeleteAsync(item);
        if (item.Active)
        {
            var fallback = (await store.ListAsync()).FirstOrDefault();
            if (fallback is null) await store.ClearSelectionAsync();
            else if (!await store.ActivateAsync(fallback))
                throw new InvalidOperationException("Could not select the fallback routing profile.");
        }
        return new RoutingProfileResult(RoutingProfileStatus.Saved, id, item.Active);
    });

    public Task<RoutingProfileResult> ActivateAsync(string id) => mutations.RunAsync(async () =>
    {
        var item = await store.FindAsync(id);
        if (item is null) return new RoutingProfileResult(RoutingProfileStatus.NotFound);
        var changed = !item.Active;
        if (changed && !await store.ActivateAsync(item)) return new RoutingProfileResult(RoutingProfileStatus.ActivateFailed);
        return new RoutingProfileResult(RoutingProfileStatus.Saved, id, changed);
    });

    public Task<RoutingProfileResult> ImportPresetsAsync() => mutations.RunAsync(async () =>
    {
        var before = await ActiveAsync();
        if (!await store.ImportPresetsAsync()) return new RoutingProfileResult(RoutingProfileStatus.ImportFailed);
        return new RoutingProfileResult(RoutingProfileStatus.Saved, AffectsCore: before != await ActiveAsync());
    });

    private async Task<ActiveRoutingConfiguration?> ActiveAsync()
    {
        var item = (await store.ListAsync()).FirstOrDefault(route => route.Active);
        return item is null ? null : new(item.Id, item.Settings.Rules, item.Settings.Enabled, item.Settings.DomainStrategy);
    }
}
