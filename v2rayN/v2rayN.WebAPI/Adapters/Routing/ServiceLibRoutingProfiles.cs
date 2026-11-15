using ServiceLib.Common;
using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using V2rayM.Application.Routing;
using V2rayM.Domain.Routing;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Routing;

internal sealed class ServiceLibRoutingProfiles(Func<Config> config, Func<Task> saveConfig) : IRoutingProfileStore
{
    public async Task<IReadOnlyList<IRoutingProfileDocument>> ListAsync() =>
        (await ConfigDbQuery.RoutingItems() ?? []).Select(item => (IRoutingProfileDocument)new Document(item)).ToArray();
    public async Task<IRoutingProfileDocument?> FindAsync(string id) =>
        await ConfigDbQuery.GetRoutingItem(id) is { } item ? new Document(item) : null;
    public Task<bool> SaveAsync(IRoutingProfileDocument document) => SaveItemAsync(((Document)document).Item);
    private async Task<bool> SaveItemAsync(RoutingItem item) => await ConfigDbHandler.SaveRoutingItem(config(), item) == 0;
    public Task DeleteAsync(IRoutingProfileDocument document) => ConfigDbHandler.RemoveRoutingItem(((Document)document).Item);
    public async Task<bool> ActivateAsync(IRoutingProfileDocument document) =>
        await ConfigDbHandler.SetDefaultRouting(config(), ((Document)document).Item) == 0;
    public async Task ClearSelectionAsync()
    {
        config().RoutingBasicItem.RoutingIndexId = string.Empty;
        await saveConfig();
    }
    public async Task<bool> ImportPresetsAsync() => await ConfigDbHandler.InitRouting(config(), true) == 0;

    public static IRoutingProfileDocument? Prepare(RoutingItem input)
    {
        var rules = JsonUtils.Deserialize<List<RulesItem>>(string.IsNullOrWhiteSpace(input.RuleSet) ? "[]" : input.RuleSet);
        if (rules is null) return null;
        ServiceLibRoutingRules.NormalizeIdentities(rules);
        var copy = JsonUtils.DeepCopy(input)!;
        copy.RuleSet = JsonUtils.Serialize(rules, false);
        copy.RuleNum = rules.Count;
        return new Document(copy);
    }

    private sealed class Document(RoutingItem item) : IRoutingProfileDocument
    {
        internal RoutingItem Item => item;
        public string Id => item.Id;
        public bool Active => item.IsActive;
        public int Sort => item.Sort;
        public RoutingProfileSettings Settings => new(item.Remarks, item.Url, item.Enabled, item.Locked,
            item.CustomIcon, item.DomainStrategy, item.RuleSet);
        public void Initialize(int sort) { item.Id = string.Empty; item.IsActive = false; item.Sort = sort; }
        public void Edit(RoutingProfileSettings settings)
        {
            item.Remarks = settings.Name!; item.Url = settings.Url!; item.Enabled = settings.Enabled;
            item.Locked = settings.Locked; item.CustomIcon = settings.Icon!; item.DomainStrategy = settings.DomainStrategy!;
            item.RuleSet = settings.Rules;
            item.RuleNum = JsonUtils.Deserialize<List<RulesItem>>(settings.Rules)!.Count;
        }
    }
}

internal static class RoutingProfileContractMapper
{
    public static OperationView Failure(RoutingProfileStatus status)
    {
        var code = status switch
        {
            RoutingProfileStatus.NotFound => "routing_profile_not_found",
            RoutingProfileStatus.ActivateFailed => "routing_profile_activate_failed",
            RoutingProfileStatus.ImportFailed => "routing_import_failed",
            _ => "routing_profile_save_failed",
        };
        return OperationView.Fail(code, status == RoutingProfileStatus.NotFound
            ? ApiMessageKeys.RoutingProfileNotFound : ApiMessageKeys.RoutingSaveFailed);
    }
}
