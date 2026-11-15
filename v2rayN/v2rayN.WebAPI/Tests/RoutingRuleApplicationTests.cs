using V2rayM.Application;
using V2rayM.Application.Routing;
using V2rayM.Domain.Routing;
using v2rayN.WebAPI.Adapters.Routing;

namespace v2rayN.WebAPI.Tests;

public class RoutingRuleApplicationTests
{
    private const string Rules = "[{\"Id\":\"a\",\"Port\":\"443\",\"Process\":[\"browser\"]},{\"Id\":\"b\",\"Port\":\"80\"}]";
    [Test]
    public async Task MoveRetainsFieldsAndUsesOriginalInsertionSlotSemantics()
    {
        var scope = new Scope(); var store = new Store(scope); var service = new RoutingRuleService(store, scope);
        var result = await service.MoveAsync("route", "a", RuleMove.Position, 2);
        await result.AffectsCore.Should().BeTrue();
        await string.Join(",", store.Parse(store.Content)!.Ids).Should().BeEqualTo("b,a");
        await store.Content.Contains("browser").Should().BeTrue();
        await store.Content.Contains("443").Should().BeTrue();
    }
    [Test]
    public async Task NoOpMoveDoesNotRestartAndOutOfBoundsNeverWrites()
    {
        var scope = new Scope(); var store = new Store(scope); var service = new RoutingRuleService(store, scope);
        var result = await service.MoveAsync("route", "a", RuleMove.Top, -1);
        await result.AffectsCore.Should().BeFalse();
        var saved = store.Writes;
        await (await service.MoveAsync("route", "a", RuleMove.Position, 3)).Status.Should().BeEqualTo(RoutingRuleStatus.MoveFailed);
        await store.Writes.Should().BeEqualTo(saved);
        await (await service.MoveAsync("route", "missing", RuleMove.Top, -1)).Status.Should().BeEqualTo(RoutingRuleStatus.RuleNotFound);
    }
    [Test]
    public async Task AppendUsesCurrentStoredRulesAndInactiveChangesDoNotAffectCore()
    {
        var scope = new Scope(); var store = new Store(scope) { Active = false }; var service = new RoutingRuleService(store, scope);
        var result = await service.SaveAsync("route", store.Parse("[{\"Id\":\"c\"}]")!, append: true);
        await string.Join(",", store.Parse(store.Content)!.Ids).Should().BeEqualTo("a,b,c");
        await result.AffectsCore.Should().BeFalse();
    }
    [Test]
    public async Task RejectedWriteIsNotReportedAsSaved()
    {
        var scope = new Scope(); var store = new Store(scope) { Reject = true }; var service = new RoutingRuleService(store, scope);
        var result = await service.DeleteAsync("route", "a");
        await result.Status.Should().BeEqualTo(RoutingRuleStatus.SaveFailed);
        await string.Join(",", store.Parse(store.Content)!.Ids).Should().BeEqualTo("a,b");
    }
    [Test]
    public async Task ImportAssignsOnlyMissingOrDuplicateIdsAndPreservesExistingIdentities()
    {
        var rules = new ServiceLib.Models.Entities.RulesItem[]
        {
            new() { Id = "kept" }, new() { Id = "kept" }, new() { Id = "" }, new() { Id = "also-kept" },
        };
        ServiceLibRoutingRules.NormalizeIdentities(rules);
        await rules[0].Id.Should().BeEqualTo("kept");
        await rules[3].Id.Should().BeEqualTo("also-kept");
        await rules.Select(rule => rule.Id).Distinct().Count().Should().BeEqualTo(4);
        var before = rules.Select(rule => rule.Id).ToArray();
        ServiceLibRoutingRules.NormalizeIdentities(rules);
        await rules.Select(rule => rule.Id).SequenceEqual(before).Should().BeTrue();
    }
    private sealed class Scope : IMutationScope
    {
        public bool Active;
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token = default)
        { Active = true; try { return await action(); } finally { Active = false; } }
    }
    private sealed class Store(Scope scope) : IRoutingRuleStore
    {
        public string Content = new ServiceLibRoutingRules().Parse(Rules)!.Content;
        public bool Active = true; public bool Reject; public int Writes;
        public Task<RoutingRuleSnapshot?> FindAsync(string id)
        { if (!scope.Active) throw new InvalidOperationException(); return Task.FromResult<RoutingRuleSnapshot?>(new(id, Active, null, Content)); }
        public Task<bool> SaveAsync(string id, IRoutingRules rules)
        { if (!scope.Active) throw new InvalidOperationException(); Writes++; if (!Reject) Content = rules.Content; return Task.FromResult(!Reject); }
        public IRoutingRules? Parse(string? content) => new ServiceLibRoutingRules().Parse(content);
        public Task<string?> DownloadAsync(string url, CancellationToken token) => throw new NotSupportedException();
    }
}
