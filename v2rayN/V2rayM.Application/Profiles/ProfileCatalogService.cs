using V2rayM.Domain.Profiles;

namespace V2rayM.Application.Profiles;

public interface IProfileCatalog
{
    string SelectedGroup { get; }
    Task<bool> GroupExistsAsync(string id);
    Task SelectGroupAsync(string id);
    Task<int> ImportAsync(string content, string groupId, bool subscription);
    Task SaveConfigurationAsync();
    Task<IReadOnlyList<string>> FindIdsAsync(IReadOnlyList<string> ids, bool ordered);
    Task<bool> CopyAsync(IReadOnlyList<string> ids);
    Task<bool> MoveToGroupAsync(IReadOnlyList<string> ids, string groupId);
    Task<IReadOnlyList<string>> OrderedIdsAsync(string groupId);
    Task<bool> ReorderAsync(IReadOnlyList<string> ids, int index, ProfileMove direction, int position);
    Task<bool> SortAsync(string groupId, ProfileSortField column, bool ascending);
}

public interface IProfileCatalogEvents
{
    void Changed(string groupId);
    void Imported(int count);
}

public enum ProfileCatalogStatus
{
    Completed, GroupNotFound, ContentRequired, ImportEmpty, ProfileNotFound,
    CopyFailed, MoveFailed, NotInGroup, ReorderFailed, SortColumnInvalid, SortFailed
}
public sealed record ProfileCatalogResult(ProfileCatalogStatus Status, int Count = 0, string? GroupId = null);

/// All existence checks, selections, writes and ordering reads participate in the same
/// mutation scope. Repository adapters must not acquire a second mutation lock.
public sealed class ProfileCatalogService(IProfileCatalog catalog, IMutationScope mutations, IProfileCatalogEvents events)
{
    public Task<ProfileCatalogResult> SelectGroupAsync(string? groupId) => mutations.RunAsync(async () =>
    {
        var id = groupId ?? string.Empty;
        if (!string.IsNullOrWhiteSpace(id) && !await catalog.GroupExistsAsync(id))
            return new ProfileCatalogResult(ProfileCatalogStatus.GroupNotFound);
        await catalog.SelectGroupAsync(id);
        await catalog.SaveConfigurationAsync();
        events.Changed(id);
        return new ProfileCatalogResult(ProfileCatalogStatus.Completed, GroupId: id);
    });

    public Task<ProfileCatalogResult> ImportAsync(string content, string? groupId, bool subscription)
    {
        if (string.IsNullOrWhiteSpace(content)) return Task.FromResult(new ProfileCatalogResult(ProfileCatalogStatus.ContentRequired));
        return mutations.RunAsync(async () =>
        {
            var id = groupId ?? catalog.SelectedGroup;
            if (id.Length > 0 && !await catalog.GroupExistsAsync(id))
                return new ProfileCatalogResult(ProfileCatalogStatus.GroupNotFound);
            var count = await catalog.ImportAsync(content, id, subscription);
            if (count <= 0) return new ProfileCatalogResult(ProfileCatalogStatus.ImportEmpty, Math.Max(count, 0));
            await catalog.SaveConfigurationAsync();
            events.Changed(id); events.Imported(count);
            return new ProfileCatalogResult(ProfileCatalogStatus.Completed, count, id);
        });
    }

    public Task<ProfileCatalogResult> CopyAsync(IEnumerable<string> profileIds)
    {
        var ids = ProfileSelection.Normalize(profileIds);
        return mutations.RunAsync(async () =>
        {
            var existing = await catalog.FindIdsAsync(ids, ordered: true);
            if (existing.Count == 0) return new ProfileCatalogResult(ProfileCatalogStatus.ProfileNotFound);
            if (!await catalog.CopyAsync(existing)) return new ProfileCatalogResult(ProfileCatalogStatus.CopyFailed);
            events.Changed(catalog.SelectedGroup);
            return new ProfileCatalogResult(ProfileCatalogStatus.Completed, existing.Count);
        });
    }

    public Task<ProfileCatalogResult> MoveToGroupAsync(IEnumerable<string> profileIds, string? groupId)
    {
        var ids = ProfileSelection.Normalize(profileIds);
        return mutations.RunAsync(async () =>
        {
            var id = groupId ?? string.Empty;
            if (id.Length > 0 && !await catalog.GroupExistsAsync(id)) return new ProfileCatalogResult(ProfileCatalogStatus.GroupNotFound);
            var existing = await catalog.FindIdsAsync(ids, ordered: false);
            if (existing.Count == 0) return new ProfileCatalogResult(ProfileCatalogStatus.ProfileNotFound);
            if (!await catalog.MoveToGroupAsync(existing, id)) return new ProfileCatalogResult(ProfileCatalogStatus.MoveFailed);
            events.Changed(catalog.SelectedGroup);
            return new ProfileCatalogResult(ProfileCatalogStatus.Completed, existing.Count, groupId);
        });
    }

    public Task<ProfileCatalogResult> ReorderAsync(string profileId, ProfileMove direction, int position) => mutations.RunAsync(async () =>
    {
        var group = catalog.SelectedGroup;
        var ids = await catalog.OrderedIdsAsync(group);
        var index = ids.ToList().IndexOf(profileId);
        if (index < 0) return new ProfileCatalogResult(ProfileCatalogStatus.NotInGroup);
        var success = await catalog.ReorderAsync(ids, index, direction, position);
        events.Changed(group);
        return new ProfileCatalogResult(success ? ProfileCatalogStatus.Completed : ProfileCatalogStatus.ReorderFailed);
    });

    public Task<ProfileCatalogResult> SortAsync(string? groupId, string column, bool ascending)
    {
        if (!Enum.TryParse<ProfileSortField>(column, true, out var field) || !Enum.IsDefined(field))
            return Task.FromResult(new ProfileCatalogResult(ProfileCatalogStatus.SortColumnInvalid));
        return mutations.RunAsync(async () =>
        {
            var group = groupId ?? catalog.SelectedGroup;
            var success = await catalog.SortAsync(group, field, ascending);
            events.Changed(group);
            return new ProfileCatalogResult(success ? ProfileCatalogStatus.Completed : ProfileCatalogStatus.SortFailed);
        });
    }
}
