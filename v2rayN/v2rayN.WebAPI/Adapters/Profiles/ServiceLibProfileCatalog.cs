using ServiceLib.Enums;
using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using V2rayM.Application.Profiles;
using V2rayM.Domain.Profiles;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal sealed class ServiceLibProfileCatalog(Func<Config> config, Func<Task> save) : IProfileCatalog
{
    public string SelectedGroup => config().SubIndexId ?? string.Empty;
    public async Task<bool> GroupExistsAsync(string id) => await ConfigDbQuery.GetSubItem(id) is not null;
    public Task SelectGroupAsync(string id) { config().SubIndexId = id; return Task.CompletedTask; }
    public Task<int> ImportAsync(string content, string groupId, bool subscription) =>
        ConfigDbHandler.AddBatchServers(config(), content, groupId, subscription);
    public Task SaveConfigurationAsync() => save();
    public async Task<IReadOnlyList<string>> FindIdsAsync(IReadOnlyList<string> ids, bool ordered) =>
        (ordered ? await ConfigDbQuery.GetProfileItemsOrderedByIndexIds(ids.ToArray())
            : await ConfigDbQuery.GetProfileItemsByIndexIds(ids.ToArray())).Select(item => item.IndexId).ToArray();
    public async Task<bool> CopyAsync(IReadOnlyList<string> ids) =>
        await ConfigDbHandler.CopyServer(config(), await ConfigDbQuery.GetProfileItemsOrderedByIndexIds(ids.ToArray())) == 0;
    public async Task<bool> MoveToGroupAsync(IReadOnlyList<string> ids, string groupId) =>
        await ConfigDbHandler.MoveToGroup(config(), await ConfigDbQuery.GetProfileItemsByIndexIds(ids.ToArray()), groupId) == 0;
    public async Task<IReadOnlyList<string>> OrderedIdsAsync(string groupId)
    {
        var items = await ConfigDbQuery.ProfileItems(groupId) ?? [];
        var extensions = (await ProfileExManager.Instance.GetProfileExs()).ToDictionary(item => item.IndexId);
        // Ordering needs only IDs and persisted sort values, not traffic, subscriptions or full UI DTOs.
        return items.OrderBy(item => extensions.GetValueOrDefault(item.IndexId)?.Sort ?? 0).Select(item => item.IndexId).ToArray();
    }
    public async Task<bool> ReorderAsync(IReadOnlyList<string> ids, int index, ProfileMove direction, int position) =>
        await ConfigDbHandler.MoveServer(config(), ids.ToList(), index, direction switch
        {
            ProfileMove.Top => EMove.Top, ProfileMove.Up => EMove.Up, ProfileMove.Down => EMove.Down,
            ProfileMove.Bottom => EMove.Bottom, ProfileMove.Position => EMove.Position,
            _ => throw new ArgumentOutOfRangeException(nameof(direction)),
        }, position) == 0;
    public async Task<bool> SortAsync(string groupId, ProfileSortField column, bool ascending) =>
        await ConfigDbHandler.SortServers(config(), groupId, column.ToString(), ascending) == 0;
}

internal sealed class ProfileCatalogEvents(Services.EventHub events, Action<string> log) : IProfileCatalogEvents
{
    public void Changed(string groupId) => events.Publish("profiles-changed", new { subscriptionId = groupId });
    public void Imported(int count) => log($"Imported {count} profile(s).");
}
