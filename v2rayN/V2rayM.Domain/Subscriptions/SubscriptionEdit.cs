namespace V2rayM.Domain.Subscriptions;

public sealed record SubscriptionEdit(
    string Remarks,
    string Url,
    string? MoreUrl = null,
    bool? Enabled = null,
    string? UserAgent = null,
    string? RequestHeaders = null,
    string? Filter = null,
    int? AutoUpdateInterval = null,
    string? ConvertTarget = null,
    string? Memo = null,
    int? Sort = null,
    string? PrevProfile = null,
    string? NextProfile = null,
    int? PreSocksPort = null,
    int? CustomCoreType = null);
