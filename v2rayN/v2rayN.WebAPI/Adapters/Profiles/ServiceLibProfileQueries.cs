using ServiceLib.Common;
using ServiceLib.Helper;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using V2rayM.Application.Profiles;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal sealed class ServiceLibProfileQueries(Func<Config> config) : IProfileQuerySource
{
    internal static async Task<(int Profiles, int Subscriptions)> CountAsync(SQLiteHelper? database = null)
    {
        database ??= SQLiteHelper.Instance;
        return (await database.TableAsync<ProfileItem>().CountAsync(),
            await database.TableAsync<SubItem>().CountAsync());
    }

    public async Task<IReadOnlyList<ProfileListEntry>> CaptureAsync(string? subscriptionId, bool includeStatistics = true)
    {
        var groupId = subscriptionId ?? config().SubIndexId ?? string.Empty;
        var profiles = await ConfigDbQuery.ProfileItems(groupId) ?? [];
        var subscriptions = (await ConfigDbQuery.SubItems() ?? []).ToDictionary(item => item.Id, item => item.Remarks);
        var extensions = await ProfileExManager.Instance.GetProfileExs();
        var extensionMap = extensions.ToDictionary(item => item.IndexId);
        var statistics = (includeStatistics && config().GuiItem.EnableStatistics ? StatisticsManager.Instance.ServerStat : null) ?? [];
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
        return entries;
    }

    // Fast observations use bounded in-memory snapshots, never reload all node
    // documents or subscription metadata from SQLite on every UI sample.
    public async Task<IReadOnlyList<ProfileObservation>> ObserveAsync()
    {
        var extensions = (await ProfileExManager.Instance.GetProfileExs()).ToDictionary(item => item.IndexId);
        var statistics = config().GuiItem.EnableStatistics ? StatisticsManager.Instance.ServerStat : [];
        var totals = statistics.ToDictionary(item => item.IndexId);
        return extensions.Keys.Concat(totals.Keys).Distinct(StringComparer.Ordinal)
            .Select(id => new ProfileObservation(id, extensions.GetValueOrDefault(id)?.Delay ?? 0,
                totals.GetValueOrDefault(id)?.TotalUp ?? 0, totals.GetValueOrDefault(id)?.TotalDown ?? 0)).ToArray();
    }

    public async Task<ProfileGroupSnapshot> CaptureGroupsAsync()
    {
        var subscriptions = await ConfigDbQuery.SubItems() ?? [];
        var profiles = await ConfigDbQuery.ProfileItems(string.Empty) ?? [];
        return new(profiles.Select(item => item.Subid ?? string.Empty).ToArray(),
            subscriptions.Select(item => new ProfileSubscription(item.Id, item.Remarks)).ToArray(), config().SubIndexId ?? string.Empty);
    }
    public bool Matches(string value, string query) => Utils.IsRegexMatch(value, query);
    internal static Task<ProfileItem?> ReadDetailsAsync(string id) => ConfigDbQuery.GetProfileItem(id);
    internal static async Task<string?> ReadSubscriptionShareAsync(string id) => (await ConfigDbQuery.GetSubItem(id))?.Url;
}
