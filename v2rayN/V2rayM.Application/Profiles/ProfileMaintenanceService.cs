namespace V2rayM.Application.Profiles;

public sealed record ProfileGroupGeneration(bool Success, string? SingleId = null, IReadOnlyList<string>? MultipleIds = null);
public interface IProfileMaintenanceStore
{
    string SelectedGroup { get; }
    Task<int> DeduplicateAsync(string group);
    Task<int> RemoveFailedAsync(string group);
    Task<bool> GroupExistsAsync(string group);
    Task<ProfileGroupGeneration> GenerateAsync(string? group, bool byRegion);
}
public sealed record ProfileGenerationResult(bool MissingGroup, ProfileGroupGeneration Result);
public sealed class ProfileMaintenanceService(IProfileMaintenanceStore store, IMutationScope mutations, IProfileCatalogEvents events)
{
    public Task<int> CleanAsync(string? group, bool duplicates) => mutations.RunAsync(async () =>
    {
        var selected = group ?? store.SelectedGroup;
        var count = duplicates ? await store.DeduplicateAsync(selected) : await store.RemoveFailedAsync(selected);
        events.Changed(selected);
        return count;
    });
    public Task<ProfileGenerationResult> GenerateAsync(string? group, bool byRegion) => mutations.RunAsync(async () =>
    {
        if (!string.IsNullOrEmpty(group) && !await store.GroupExistsAsync(group)) return new ProfileGenerationResult(true, new(false));
        var result = await store.GenerateAsync(group, byRegion);
        if (result.Success) events.Changed(group ?? string.Empty);
        return new ProfileGenerationResult(false, result);
    });
}
