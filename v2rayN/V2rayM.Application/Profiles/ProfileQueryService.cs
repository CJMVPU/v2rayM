namespace V2rayM.Application.Profiles;

public sealed record ProfileListEntry(
    string IndexId,
    string Remarks,
    string Protocol,
    string Address,
    int Port,
    string Network,
    string StreamSecurity,
    string? SubscriptionId,
    string? SubscriptionName,
    string CoreType,
    int Sort,
    int Delay,
    decimal Speed,
    string? IpInfo,
    long TodayUp,
    long TodayDown,
    long TotalUp,
    long TotalDown,
    bool IsCurrent,
    bool CanTest);

public sealed record ProfileSubscription(string Id, string Name);
public sealed record ProfileGroupSnapshot(IReadOnlyList<string> ProfileGroups, IReadOnlyList<ProfileSubscription> Subscriptions, string SelectedGroup);
public sealed record ProfileGroupEntry(string Id, string? Name, bool All, int Count, bool Selected);
public interface IProfileQuerySource
{
    Task<IReadOnlyList<ProfileListEntry>> CaptureAsync(string? subscriptionId);
    Task<ProfileGroupSnapshot> CaptureGroupsAsync();
    bool Matches(string value, string query);
}

/// Read models belong to the application, not the domain aggregate or HTTP contract.
public sealed class ProfileQueryService(IProfileQuerySource source)
{
    public async Task<IReadOnlyList<ProfileListEntry>> ListAsync(string? group, string? filter)
    {
        var snapshot = await source.CaptureAsync(group);
        var query = filter?.Trim();
        return snapshot.Where(item => string.IsNullOrEmpty(query)
            || source.Matches(item.Remarks, query) || source.Matches(item.Address, query))
            .OrderBy(item => item.Sort).ToArray();
    }
    public async Task<IReadOnlyList<ProfileGroupEntry>> GroupsAsync()
    {
        var snapshot = await source.CaptureGroupsAsync();
        var counts = snapshot.ProfileGroups.GroupBy(group => group)
            .ToDictionary(group => group.Key, group => group.Count());
        var result = new List<ProfileGroupEntry> { new(string.Empty, null, true, snapshot.ProfileGroups.Count, string.IsNullOrEmpty(snapshot.SelectedGroup)) };
        result.AddRange(snapshot.Subscriptions.Select(group => new ProfileGroupEntry(group.Id, group.Name, false,
            counts.GetValueOrDefault(group.Id), group.Id == snapshot.SelectedGroup)));
        return result;
    }
}
