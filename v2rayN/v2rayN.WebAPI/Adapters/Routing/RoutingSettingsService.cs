using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Models.Entities;
using V2rayM.Application.Routing;
using V2rayM.Domain.Routing;
using v2rayN.WebAPI.Contracts;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Adapters.Routing;

// HTTP/upstream mapping stays here; application use cases own routing rules and
// storage commands. All mutations use the host's existing settings transaction.
internal interface IRoutingSettingsRuntime
{
    Task<CoreSettingsApplyContext> BeginAsync();
    Task<T> MutateAsync<T>(CoreSettingsApplyContext context, Func<Task<T>> change, Func<T, bool> succeeded);
    Task<OperationView> CompleteAsync(string section, bool changed, CoreSettingsApplyContext context,
        string successMessageKey = ApiMessageKeys.CommonSaved, object? data = null);
}

internal sealed class RoutingSettingsService(RoutingProfileService profiles, RoutingRuleService ruleService,
    IRoutingSettingsRuntime runtime)
{
    public async Task<IReadOnlyList<RoutingItem>> GetRoutingProfilesAsync() => await ConfigDbQuery.RoutingItems() ?? [];

    public async Task<OperationView> SaveRoutingProfileAsync(RoutingItem input, string? routingId = null)
    {
        if (string.IsNullOrWhiteSpace(input.Remarks))
        {
            return OperationView.Fail("routing_name_required", ApiMessageKeys.RoutingNameRequired);
        }
        if (!Global.DomainStrategies.AppendEmpty().Contains(input.DomainStrategy ?? string.Empty))
        {
            return OperationView.Fail("routing_strategy_invalid", ApiMessageKeys.SettingsInvalidRoutingStrategy);
        }

        var document = ServiceLibRoutingProfiles.Prepare(input);
        if (document is null)
            return OperationView.Fail("routing_rules_json_invalid", ApiMessageKeys.RoutingRulesInvalid);
        return await ApplyRoutingProfileAsync(() => profiles.SaveAsync(document, routingId));
    }

    public Task<OperationView> DeleteRoutingProfileAsync(string id) =>
        ApplyRoutingProfileAsync(() => profiles.DeleteAsync(id), ApiMessageKeys.CommonDeleted);

    public Task<OperationView> ActivateRoutingProfileAsync(string id) =>
        ApplyRoutingProfileAsync(() => profiles.ActivateAsync(id), ApiMessageKeys.CommonCompleted);

    private async Task<OperationView> ApplyRoutingProfileAsync(Func<Task<RoutingProfileResult>> change, string messageKey = ApiMessageKeys.CommonSaved)
    {
        await using var context = await runtime.BeginAsync();
        if (context.Failure is { } failure) return failure;
        var result = await runtime.MutateAsync(context, change, value => value.Status == RoutingProfileStatus.Saved);
        if (result.Status != RoutingProfileStatus.Saved) return RoutingProfileContractMapper.Failure(result.Status);
        return await runtime.CompleteAsync("routing-profiles", result.AffectsCore, context,
            messageKey, result.Id is null ? null : new { routingId = result.Id });
    }

    public Task<IReadOnlyList<RulesItem>> GetRoutingRulesAsync(string routingId) => ServiceLibRoutingRules.ReadAsync(routingId);

    public Task<OperationView> SaveRoutingRulesAsync(string routingId, IEnumerable<RulesItem> rules) =>
        ApplyRoutingRulesAsync(routingId, () => ruleService.SaveAsync(routingId, ServiceLibRoutingRules.FromItems(rules)));

    private async Task<OperationView> ApplyRoutingRulesAsync(string routingId, Func<Task<RoutingRuleResult>> change)
    {
        await using var context = await runtime.BeginAsync();
        if (context.Failure is { } failure) return failure;
        var result = await runtime.MutateAsync(context, change, value => value.Status == RoutingRuleStatus.Saved);
        if (result.Status != RoutingRuleStatus.Saved) return RoutingRuleContractMapper.Failure(result.Status);
        return await runtime.CompleteAsync("routing-rules", result.AffectsCore, context, data: new { routingId });
    }

    public Task<OperationView> ImportRoutingRulesAsync(string routingId, RouteRulesImportInput request)
    {
        var rules = ruleService.Parse(request.Content);
        return rules is null ? Task.FromResult(RoutingRuleContractMapper.Failure(RoutingRuleStatus.InvalidJson))
            : ApplyRoutingRulesAsync(routingId, () => ruleService.SaveAsync(routingId, rules, request.Append));
    }

    public async Task<OperationView> ImportRoutingRulesFromUrlAsync(string routingId, bool append, CancellationToken cancellationToken)
    {
        var download = await ruleService.DownloadAsync(routingId, cancellationToken);
        if (download.Status != RoutingRuleStatus.Saved) return RoutingRuleContractMapper.Failure(download.Status);
        return await ApplyRoutingRulesAsync(routingId, () => ruleService.SaveAsync(routingId, download.Rules!, append));
    }

    public Task<OperationView> MoveRoutingRuleAsync(string routingId, string ruleId, EMove direction, int position)
    {
        var move = direction switch
        {
            EMove.Top => RuleMove.Top, EMove.Up => RuleMove.Up, EMove.Down => RuleMove.Down,
            EMove.Bottom => RuleMove.Bottom, EMove.Position => RuleMove.Position,
            _ => (RuleMove?)null,
        };
        return move is null ? Task.FromResult(RoutingRuleContractMapper.Failure(RoutingRuleStatus.MoveFailed))
            : ApplyRoutingRulesAsync(routingId, () => ruleService.MoveAsync(routingId, ruleId, move.Value, position));
    }

    public Task<OperationView> DeleteRoutingRuleAsync(string routingId, string ruleId) =>
        ApplyRoutingRulesAsync(routingId, () => ruleService.DeleteAsync(routingId, ruleId));

    public Task<OperationView> ImportRoutingProfilesAsync() =>
        ApplyRoutingProfileAsync(profiles.ImportPresetsAsync, ApiMessageKeys.CommonCompleted);

}
