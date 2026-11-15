using ServiceLib.Common;
using ServiceLib.Handler;
using ServiceLib.Helper;
using ServiceLib.Manager;
using ServiceLib.Models.Entities;
using ServiceLib.Services;
using V2rayM.Application.Routing;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Routing;

internal sealed class ServiceLibRoutingRules : IRoutingRuleStore
{
    public async Task<RoutingRuleSnapshot?> FindAsync(string id) => await ConfigDbQuery.GetRoutingItem(id) is { } item
        ? new(item.Id, item.IsActive, item.Url, item.RuleSet) : null;
    public async Task<bool> SaveAsync(string id, IRoutingRules rules)
    {
        var item = await ConfigDbQuery.GetRoutingItem(id);
        if (item is null) return false;
        var entries = JsonUtils.Deserialize<List<RulesItem>>(rules.Content);
        if (entries is null) return false;
        NormalizeIdentities(entries);
        item.RuleNum = entries.Count;
        item.RuleSet = JsonUtils.Serialize(entries, false);
        // Upstream batch import regenerates every ID. Editing must retain stable rule
        // identities so moving/deleting another rule cannot invalidate clients' selections.
        return await SQLiteHelper.Instance.ReplaceAsync(item) > 0;
    }
    internal static void NormalizeIdentities(IReadOnlyList<RulesItem> entries)
    {
        var used = new HashSet<string>(StringComparer.Ordinal);
        var reserved = entries.Select(rule => rule.Id).Where(id => !string.IsNullOrWhiteSpace(id)).ToHashSet(StringComparer.Ordinal);
        foreach (var rule in entries)
        {
            if (!string.IsNullOrWhiteSpace(rule.Id) && used.Add(rule.Id)) continue;
            string id;
            do { id = Utils.GetGuid(false); } while (reserved.Contains(id) || !used.Add(id));
            rule.Id = id;
        }
    }
    public IRoutingRules? Parse(string? content) => JsonUtils.Deserialize<List<RulesItem>>(content) is { } rules ? new Document(rules) : null;
    public Task<string?> DownloadAsync(string url, CancellationToken token) =>
        new DownloadService().TryDownloadString(url, true, string.Empty, token);
    public static IRoutingRules FromItems(IEnumerable<RulesItem> items) => new Document(items.ToList());
    public static async Task<IReadOnlyList<RulesItem>> ReadAsync(string id) =>
        JsonUtils.Deserialize<List<RulesItem>>((await ConfigDbQuery.GetRoutingItem(id))?.RuleSet ?? "[]") ?? [];
    private sealed class Document(List<RulesItem> rules) : IRoutingRules
    {
        public string Content => JsonUtils.Serialize(rules, false);
        public IReadOnlyList<string> Ids => rules.Select(rule => rule.Id).ToArray();
        public void Append(IRoutingRules incoming) => rules.AddRange(JsonUtils.Deserialize<List<RulesItem>>(incoming.Content)!);
        public void Move(int index, int destination)
        {
            if (index == destination) return;
            var rule = rules[index]; rules.RemoveAt(index); rules.Insert(destination, rule);
        }
        public bool Remove(string id) => rules.RemoveAll(rule => rule.Id == id) > 0;
    }
}

internal static class RoutingRuleContractMapper
{
    public static OperationView Failure(RoutingRuleStatus status)
    {
        var (code, key) = status switch
        {
            RoutingRuleStatus.ProfileNotFound => ("routing_profile_not_found", ApiMessageKeys.RoutingProfileNotFound),
            RoutingRuleStatus.RuleNotFound => ("routing_rule_not_found", ApiMessageKeys.RoutingRuleNotFound),
            RoutingRuleStatus.InvalidJson => ("routing_rules_json_invalid", ApiMessageKeys.RoutingRulesInvalid),
            RoutingRuleStatus.MoveFailed => ("routing_rule_move_failed", ApiMessageKeys.CommonInvalidInput),
            RoutingRuleStatus.InvalidUrl => ("routing_url_invalid", "routing.urlInvalid"),
            RoutingRuleStatus.DownloadFailed => ("routing_url_download_failed", "routing.urlImportFailedGeneric"),
            _ => ("routing_rules_save_failed", ApiMessageKeys.RoutingSaveFailed),
        };
        return OperationView.Fail(code, key);
    }
}
