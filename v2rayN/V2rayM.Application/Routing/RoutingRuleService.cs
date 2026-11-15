using V2rayM.Domain.Routing;

namespace V2rayM.Application.Routing;

public interface IRoutingRules
{
    string Content { get; }
    IReadOnlyList<string> Ids { get; }
    void Append(IRoutingRules incoming);
    void Move(int index, int destination);
    bool Remove(string id);
}
public sealed record RoutingRuleSnapshot(string Id, bool Active, string? Url, string? Content);
public interface IRoutingRuleStore
{
    Task<RoutingRuleSnapshot?> FindAsync(string id);
    Task<bool> SaveAsync(string id, IRoutingRules rules);
    IRoutingRules? Parse(string? content);
    Task<string?> DownloadAsync(string url, CancellationToken token);
}
public enum RoutingRuleStatus { Saved, ProfileNotFound, RuleNotFound, InvalidJson, SaveFailed, MoveFailed, InvalidUrl, DownloadFailed }
public sealed record RoutingRuleResult(RoutingRuleStatus Status, bool AffectsCore = false);
public sealed record RoutingRuleDownload(RoutingRuleStatus Status, IRoutingRules? Rules = null);

public sealed class RoutingRuleService(IRoutingRuleStore store, IMutationScope mutations)
{
    public IRoutingRules? Parse(string? content) => store.Parse(content);
    public Task<RoutingRuleResult> SaveAsync(string id, IRoutingRules rules, bool append = false) =>
        ChangeAsync(id, existing =>
        {
            if (!append) return (RoutingRuleStatus.Saved, rules);
            var combined = store.Parse(existing.Content ?? "[]") ?? store.Parse("[]")!;
            combined.Append(rules);
            return (RoutingRuleStatus.Saved, combined);
        });

    public Task<RoutingRuleResult> MoveAsync(string id, string ruleId, RuleMove direction, int position) =>
        ChangeAsync(id, existing =>
        {
            var rules = store.Parse(existing.Content ?? "[]") ?? store.Parse("[]")!;
            var index = rules.Ids.ToList().IndexOf(ruleId);
            if (index < 0) return (RoutingRuleStatus.RuleNotFound, rules);
            var destination = RuleOrder.Destination(rules.Ids.Count, index, direction, position);
            if (destination is null) return (RoutingRuleStatus.MoveFailed, rules);
            rules.Move(index, destination.Value);
            return (RoutingRuleStatus.Saved, rules);
        });
    public Task<RoutingRuleResult> DeleteAsync(string id, string ruleId) => ChangeAsync(id, existing =>
    {
        var rules = store.Parse(existing.Content ?? "[]") ?? store.Parse("[]")!;
        return (rules.Remove(ruleId) ? RoutingRuleStatus.Saved : RoutingRuleStatus.RuleNotFound, rules);
    });
    private Task<RoutingRuleResult> ChangeAsync(string id, Func<RoutingRuleSnapshot, (RoutingRuleStatus Status, IRoutingRules Rules)> change) =>
        mutations.RunAsync(async () =>
        {
            var before = await store.FindAsync(id);
            if (before is null) return new RoutingRuleResult(RoutingRuleStatus.ProfileNotFound);
            var edit = change(before);
            if (edit.Status != RoutingRuleStatus.Saved) return new RoutingRuleResult(edit.Status);
            if (!await store.SaveAsync(id, edit.Rules)) return new RoutingRuleResult(RoutingRuleStatus.SaveFailed);
            var after = await store.FindAsync(id);
            return new RoutingRuleResult(RoutingRuleStatus.Saved, before.Active && before.Content != after?.Content);
        });
    public async Task<RoutingRuleDownload> DownloadAsync(string id, CancellationToken token)
    {
        var item = await store.FindAsync(id);
        if (item is null) return new(RoutingRuleStatus.ProfileNotFound);
        if (!Uri.TryCreate(item.Url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            return new(RoutingRuleStatus.InvalidUrl);
        var content = await store.DownloadAsync(uri.AbsoluteUri, token);
        if (string.IsNullOrWhiteSpace(content)) return new(RoutingRuleStatus.DownloadFailed);
        var rules = store.Parse(content);
        return rules is null ? new(RoutingRuleStatus.InvalidJson) : new(RoutingRuleStatus.Saved, rules);
    }
}
