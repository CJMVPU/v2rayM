namespace V2rayM.Domain.Subscriptions;

public enum SubscriptionValidation { Valid, NameRequired, InvalidUrl, InvalidHeaders }

/// Subscription identity and editable settings. Core identifiers are opaque stored metadata,
/// never authorization to launch a core. Unknown persisted values survive reads.
public sealed record Subscription(string Id, string Remarks, string Url, string MoreUrl,
    bool Enabled, string UserAgent, string? RequestHeaders, string? Filter,
    int AutoUpdateInterval, long UpdateTime, string? ConvertTarget, string? Memo, int Sort,
    string? PrevProfile, string? NextProfile, int? PreSocksPort, int? CustomCoreType)
{
    // Preserve upstream scheduling: disabled subscriptions are filtered by the update adapter.
    public bool IsUpdateDue(long unixTime) => AutoUpdateInterval > 0
        && unixTime - UpdateTime >= AutoUpdateInterval * 60L;

    public static SubscriptionValidation Validate(SubscriptionEdit edit, bool headersValid)
    {
        if (string.IsNullOrWhiteSpace(edit.Remarks)) return SubscriptionValidation.NameRequired;
        if (!string.IsNullOrWhiteSpace(edit.Url) &&
            (!Uri.TryCreate(edit.Url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")))
            return SubscriptionValidation.InvalidUrl;
        return headersValid ? SubscriptionValidation.Valid : SubscriptionValidation.InvalidHeaders;
    }

    public static Subscription Apply(SubscriptionEdit edit, Subscription? existing) => new(
        existing?.Id ?? string.Empty, edit.Remarks.Trim(), edit.Url?.Trim() ?? string.Empty,
        edit.MoreUrl?.Trim() ?? existing?.MoreUrl ?? string.Empty,
        edit.Enabled ?? existing?.Enabled ?? true,
        edit.UserAgent?.Trim() ?? existing?.UserAgent ?? string.Empty,
        edit.RequestHeaders ?? existing?.RequestHeaders, edit.Filter ?? existing?.Filter,
        Math.Max(edit.AutoUpdateInterval ?? existing?.AutoUpdateInterval ?? 0, 0), existing?.UpdateTime ?? 0,
        edit.ConvertTarget ?? existing?.ConvertTarget, edit.Memo ?? existing?.Memo,
        edit.Sort ?? existing?.Sort ?? 0, edit.PrevProfile ?? existing?.PrevProfile,
        edit.NextProfile ?? existing?.NextProfile, edit.PreSocksPort, edit.CustomCoreType);
}
