using ServiceLib.Enums;
using ServiceLib.Handler;
using ServiceLib.Helper;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using V2rayM.Application.Subscriptions;
using V2rayM.Domain.Subscriptions;

namespace v2rayN.WebAPI.Adapters.Subscriptions;

internal sealed class ServiceLibSubscriptionHeaders : ISubscriptionHeaders
{
    public bool IsValid(string? headers) => HttpRequestHeadersHelper.TryParse(headers, out _);
}

internal sealed class ServiceLibSubscriptionRepository(Func<Config> config) : ISubscriptionRepository
{
    public async Task<IReadOnlyList<Subscription>> ListAsync() =>
        (await ConfigDbQuery.SubItems() ?? []).Select(ToDomain).ToArray();
    public async Task<Subscription?> FindAsync(string id) =>
        await ConfigDbQuery.GetSubItem(id) is { } item ? ToDomain(item) : null;
    public async Task<Subscription?> SaveAsync(Subscription subscription)
    {
        // Reload inside the shared mutation scope, retaining fields introduced upstream.
        var existing = string.IsNullOrEmpty(subscription.Id) ? null : await ConfigDbQuery.GetSubItem(subscription.Id);
        if (!string.IsNullOrEmpty(subscription.Id) && existing is null) return null;
        var item = ApplyToItem(subscription, existing ?? new SubItem());
        if (await ConfigDbHandler.AddSubItem(config(), item) != 0) return null;
        return await FindAsync(item.Id);
    }

    internal static Subscription ToDomain(SubItem item) => new(item.Id, item.Remarks, item.Url,
        item.MoreUrl, item.Enabled, item.UserAgent, item.RequestHeaders, item.Filter,
        item.AutoUpdateInterval, item.UpdateTime, item.ConvertTarget, item.Memo, item.Sort,
        item.PrevProfile, item.NextProfile, item.PreSocksPort, (int?)item.CustomCoreType);

    internal static SubItem ApplyToItem(Subscription value, SubItem item)
    {
        item.Id = value.Id; item.Remarks = value.Remarks; item.Url = value.Url;
        item.MoreUrl = value.MoreUrl; item.Enabled = value.Enabled; item.UserAgent = value.UserAgent;
        item.RequestHeaders = value.RequestHeaders; item.Filter = value.Filter;
        item.AutoUpdateInterval = value.AutoUpdateInterval; item.UpdateTime = value.UpdateTime;
        item.ConvertTarget = value.ConvertTarget; item.Memo = value.Memo; item.Sort = value.Sort;
        item.PrevProfile = value.PrevProfile; item.NextProfile = value.NextProfile;
        item.PreSocksPort = value.PreSocksPort; item.CustomCoreType = (ECoreType?)value.CustomCoreType;
        return item;
    }
}
