using V2rayM.Application;
using V2rayM.Application.Routing;
using V2rayM.Domain.Routing;
using v2rayN.WebAPI.Adapters.Routing;

namespace v2rayN.WebAPI.Tests;

public class RoutingProfileApplicationTests
{
    [Test]
    public async Task EditPreservesStoredIdentityActivationOrderingAndUnexposedFields()
    {
        var scope = new Scope(); var store = new Store(scope);
        var original = new Document("stored", true, 7) { Extra = "future-upstream-field" };
        store.Items.Add(original);
        var input = new Document("spoofed", false, 99) { Settings = original.Settings with { Name = "edited" } };
        var result = await new RoutingProfileService(store, scope).SaveAsync(input, "stored");
        await result.Status.Should().BeEqualTo(RoutingProfileStatus.Saved);
        await result.AffectsCore.Should().BeTrue();
        await result.Id.Should().BeEqualTo("stored");
        await original.Sort.Should().BeEqualTo(7);
        await original.Active.Should().BeTrue();
        await original.Extra.Should().BeEqualTo("future-upstream-field");
        await original.Settings.Name.Should().BeEqualTo("edited");
    }
    [Test]
    public async Task NewProfileCannotClaimIdentityOrActivationAndUsesNextSort()
    {
        var scope = new Scope(); var store = new Store(scope);
        store.Items.Add(new Document("existing", true, 12));
        var input = new Document("existing", true, 0);
        var result = await new RoutingProfileService(store, scope).SaveAsync(input);
        await result.AffectsCore.Should().BeFalse();
        await input.Sort.Should().BeEqualTo(13);
        await input.Active.Should().BeFalse();
        await result.Id.Should().BeEqualTo("created");
        await store.Items.Count.Should().BeEqualTo(2);
    }
    [Test]
    public async Task NoOpEditAndRepeatedActivationDoNotRestartOrActivateAgain()
    {
        var scope = new Scope(); var store = new Store(scope);
        store.Items.Add(new Document("active", true, 1));
        var service = new RoutingProfileService(store, scope);
        await (await service.SaveAsync(new Document("ignored", false, 99), "active")).AffectsCore.Should().BeFalse();
        await (await service.ActivateAsync("active")).AffectsCore.Should().BeFalse();
        await store.Activations.Should().BeEqualTo(0);
    }
    [Test]
    public async Task ActiveDeletionSelectsFirstRemainingProfileUnderMutationScope()
    {
        var scope = new Scope(); var store = new Store(scope);
        store.Items.AddRange([new Document("active", true, 1), new Document("fallback", false, 2), new Document("later", false, 3)]);
        var result = await new RoutingProfileService(store, scope).DeleteAsync("active");
        await result.AffectsCore.Should().BeTrue();
        await store.Items.First().Active.Should().BeTrue();
        await store.Items.First().Id.Should().BeEqualTo("fallback");
        await store.Clears.Should().BeEqualTo(0);
    }
    [Test]
    public async Task LastActiveDeletionClearsLegacySelectionButInactiveDeletionDoesNot()
    {
        var scope = new Scope(); var store = new Store(scope);
        store.Items.AddRange([new Document("inactive", false, 1), new Document("active", true, 2)]);
        var service = new RoutingProfileService(store, scope);
        await (await service.DeleteAsync("inactive")).AffectsCore.Should().BeFalse();
        await store.Clears.Should().BeEqualTo(0);
        await (await service.DeleteAsync("active")).AffectsCore.Should().BeTrue();
        await store.Clears.Should().BeEqualTo(1);
    }
    [Test]
    public async Task MissingAndRejectedWritesReturnFailuresWithoutRestart()
    {
        var scope = new Scope(); var store = new Store(scope) { Reject = true };
        store.Items.Add(new Document("inactive", false, 1));
        var service = new RoutingProfileService(store, scope);
        await (await service.DeleteAsync("missing")).Status.Should().BeEqualTo(RoutingProfileStatus.NotFound);
        await (await service.ActivateAsync("missing")).Status.Should().BeEqualTo(RoutingProfileStatus.NotFound);
        await (await service.SaveAsync(new Document("input", false, 1), "missing")).Status.Should().BeEqualTo(RoutingProfileStatus.NotFound);
        await (await service.SaveAsync(new Document("input", false, 1))).Status.Should().BeEqualTo(RoutingProfileStatus.SaveFailed);
        await (await service.ActivateAsync("inactive")).Status.Should().BeEqualTo(RoutingProfileStatus.ActivateFailed);
        await (await service.ImportPresetsAsync()).Status.Should().BeEqualTo(RoutingProfileStatus.ImportFailed);
    }
    [Test]
    public async Task PresetImportComparesActiveConfigurationWithinSameMutation()
    {
        var scope = new Scope(); var store = new Store(scope);
        store.Items.Add(new Document("active", true, 1));
        var service = new RoutingProfileService(store, scope);
        store.OnImport = () => store.Items.Add(new Document("inactive", false, 2));
        await (await service.ImportPresetsAsync()).AffectsCore.Should().BeFalse();
        store.OnImport = () => store.Items[0].Settings = store.Items[0].Settings with { Rules = "changed" };
        await (await service.ImportPresetsAsync()).AffectsCore.Should().BeTrue();
    }
    [Test]
    public async Task AdapterPreparationPreservesRuleIdsWithoutMutatingCallerDocument()
    {
        var input = new ServiceLib.Models.Entities.RoutingItem { Id = "stored", IsActive = true, Sort = 5,
            RuleSet = "[{\"Id\":\"stable\",\"Process\":[\"browser\"]},{\"Id\":\"\"}]" };
        var prepared = ServiceLibRoutingProfiles.Prepare(input)!;
        var rules = new ServiceLibRoutingRules().Parse(prepared.Settings.Rules)!;
        await rules.Ids[0].Should().BeEqualTo("stable");
        await string.IsNullOrEmpty(rules.Ids[1]).Should().BeFalse();
        await prepared.Settings.Rules.Contains("browser").Should().BeTrue();
        prepared.Initialize(9);
        await input.Id.Should().BeEqualTo("stored");
        await input.Sort.Should().BeEqualTo(5);
        await input.IsActive.Should().BeTrue();
        await input.RuleSet.Contains("\"Id\":\"\"").Should().BeTrue();
    }
    private sealed class Scope : IMutationScope
    {
        public bool Active;
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token = default)
        { Active = true; try { return await action(); } finally { Active = false; } }
    }
    private sealed class Document(string id, bool active, int sort) : IRoutingProfileDocument
    {
        public string Id { get; set; } = id;
        public bool Active { get; set; } = active;
        public int Sort { get; set; } = sort;
        public string? Extra;
        public RoutingProfileSettings Settings { get; set; } = new("name", null, true, false, null, null, "[]");
        public void Initialize(int order) { Id = ""; Active = false; Sort = order; }
        public void Edit(RoutingProfileSettings settings) => Settings = settings;
    }
    private sealed class Store(Scope scope) : IRoutingProfileStore
    {
        public List<Document> Items = [];
        public bool Reject;
        public int Activations, Clears;
        public Action? OnImport;
        private void Check() { if (!scope.Active) throw new InvalidOperationException("Mutation scope required"); }
        public Task<IReadOnlyList<IRoutingProfileDocument>> ListAsync()
        { Check(); return Task.FromResult<IReadOnlyList<IRoutingProfileDocument>>(Items.ToArray()); }
        public Task<IRoutingProfileDocument?> FindAsync(string id)
        { Check(); return Task.FromResult<IRoutingProfileDocument?>(Items.Find(item => item.Id == id)); }
        public Task<bool> SaveAsync(IRoutingProfileDocument document)
        {
            Check(); var item = (Document)document;
            if (!Reject && item.Id == "") { item.Id = "created"; Items.Add(item); }
            return Task.FromResult(!Reject);
        }
        public Task DeleteAsync(IRoutingProfileDocument document) { Check(); Items.Remove((Document)document); return Task.CompletedTask; }
        public Task<bool> ActivateAsync(IRoutingProfileDocument document)
        { Check(); Activations++; if (!Reject) foreach (var item in Items) item.Active = item.Id == document.Id; return Task.FromResult(!Reject); }
        public Task ClearSelectionAsync() { Check(); Clears++; return Task.CompletedTask; }
        public Task<bool> ImportPresetsAsync() { Check(); if (!Reject) OnImport?.Invoke(); return Task.FromResult(!Reject); }
    }
}
