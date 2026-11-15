using ServiceLib.Common;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using V2rayM.Application.Profiles;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal sealed class ServiceLibProfileQueries(Func<Config> config) : IProfileQuerySource
{
    public async Task<ProfileQuerySnapshot> CaptureAsync(string? subscriptionId)
    {
        var groupId = subscriptionId ?? config().SubIndexId ?? string.Empty;
        var profiles = await AppManager.Instance.ProfileItems(groupId) ?? [];
        var subscriptions = (await AppManager.Instance.SubItems() ?? []).ToDictionary(item => item.Id, item => item.Remarks);
        var extensions = await ProfileExManager.Instance.GetProfileExs();
        var extensionMap = extensions.ToDictionary(item => item.IndexId);
        var statistics = (config().GuiItem.EnableStatistics ? StatisticsManager.Instance.ServerStat : null) ?? [];
        var statisticsMap = statistics.ToDictionary(item => item.IndexId);

        var entries = profiles
            .Select(item =>
            {
                extensionMap.TryGetValue(item.IndexId, out var extension);
                statisticsMap.TryGetValue(item.IndexId, out var statistic);
                var delay = extension?.Delay ?? 0;
                var speed = extension?.Speed ?? 0;
                return new ProfileListEntry(
                    item.IndexId,
                    item.Remarks,
                    System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(item.ConfigType.ToString()),
                    item.Address,
                    item.Port,
                    item.GetNetwork(),
                    item.StreamSecurity,
                    item.Subid,
                    subscriptions.GetValueOrDefault(item.Subid),
                    System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(AppManager.Instance.GetCoreType(item, item.ConfigType).ToString()),
                    extension?.Sort ?? 0,
                    delay,
                    speed,
                    extension?.IpInfo,
                    statistic?.TodayUp ?? 0,
                    statistic?.TodayDown ?? 0,
                    statistic?.TotalUp ?? 0,
                    statistic?.TotalDown ?? 0,
                    item.IndexId == config().IndexId,
                    !item.IsComplex() && item.Port > 0);
            })
            .ToArray();
        return new(entries, subscriptions.Select(item => new ProfileSubscription(item.Key, item.Value)).ToArray(), config().SubIndexId ?? string.Empty);
    }

    public async Task<ProfileGroupSnapshot> CaptureGroupsAsync()
    {
        var subscriptions = await AppManager.Instance.SubItems() ?? [];
        var profiles = await AppManager.Instance.ProfileItems(string.Empty) ?? [];
        return new(profiles.Select(item => item.Subid ?? string.Empty).ToArray(),
            subscriptions.Select(item => new ProfileSubscription(item.Id, item.Remarks)).ToArray(), config().SubIndexId ?? string.Empty);
    }
    public bool Matches(string value, string query) => Utils.IsRegexMatch(value, query);
    internal static Task<ProfileItem?> ReadDetailsAsync(string id) => AppManager.Instance.GetProfileItem(id);
    internal static async Task<string?> ReadSubscriptionShareAsync(string id) => (await AppManager.Instance.GetSubItem(id))?.Url;
}
