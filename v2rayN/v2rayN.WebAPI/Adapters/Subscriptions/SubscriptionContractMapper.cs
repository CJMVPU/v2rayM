using ServiceLib.Enums;
using V2rayM.Domain.Subscriptions;
using V2rayM.Application.Subscriptions;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Subscriptions;

internal static class SubscriptionContractMapper
{
    public static SubscriptionEdit ToEdit(SubscriptionInput input) => new(input.Remarks, input.Url,
        input.MoreUrl, input.Enabled, input.UserAgent, input.RequestHeaders, input.Filter,
        input.AutoUpdateInterval, input.ConvertTarget, input.Memo, input.Sort,
        input.PrevProfile, input.NextProfile, input.PreSocksPort, (int?)input.CustomCoreType);

    public static SubscriptionView ToView(Subscription item) => new(item.Id, item.Remarks,
        item.Url, item.Enabled, item.MoreUrl, item.Filter, item.AutoUpdateInterval, item.UpdateTime,
        item.UserAgent, item.RequestHeaders, item.ConvertTarget, item.Memo, item.Sort,
        item.PrevProfile, item.NextProfile, item.PreSocksPort,
        item.CustomCoreType is null ? null : System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(((ECoreType)item.CustomCoreType.Value).ToString()));

    public static SubscriptionMutationResult ToResult(SubscriptionSaveResult result)
    {
        var (code, key) = result.Status switch
        {
            SubscriptionSaveStatus.Added => ("ok", ApiMessageKeys.SubscriptionAdded),
            SubscriptionSaveStatus.Saved => ("ok", ApiMessageKeys.SubscriptionSaved),
            SubscriptionSaveStatus.NotFound => ("subscription_not_found", ApiMessageKeys.SubscriptionNotFound),
            SubscriptionSaveStatus.NameRequired => ("subscription_name_required", ApiMessageKeys.SubscriptionNameRequired),
            SubscriptionSaveStatus.InvalidUrl => ("subscription_url_invalid", ApiMessageKeys.SubscriptionInvalidUrl),
            SubscriptionSaveStatus.InvalidHeaders => ("subscription_headers_invalid", ApiMessageKeys.CommonInvalidInput),
            _ => ("subscription_save_failed", ApiMessageKeys.SubscriptionSaveFailed),
        };
        return new(code == "ok", code, key, result.Subscription is { } item ? ToView(item) : null);
    }
}
