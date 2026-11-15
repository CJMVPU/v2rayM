using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Models.Configs;
using V2rayM.Application;
using V2rayM.Application.Settings;
using V2rayM.Domain.Settings;
using v2rayN.WebAPI.Adapters.Settings;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class SettingsEditorApplicationTests
{
    [Test]
    public async Task TunToggleUsesFingerprintPreservesHiddenTunFieldsAndCompensatesFailedSave()
    {
        var scope = new Scope(); var store = new Store(scope); var effects = new Effects(scope, store);
        var service = Service(store, scope, effects);
        var result = await service.EditAsync(new(TunEnabled: true));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.Saved);
        await result.CoreChanged.Should().BeTrue();
        await store.Current.TunModeItem.IPv4Address.Should().BeEqualTo("hidden-address");
        var unchanged = await service.EditAsync(new(TunEnabled: true));
        await unchanged.CoreChanged.Should().BeFalse();
        store.FailSave = true;
        var failed = await service.EditAsync(new(TunEnabled: false));
        await failed.Status.Should().BeEqualTo(SettingsEditStatus.PersistenceFailed);
        await failed.ConfigRestored.Should().BeTrue();
        await store.Current.TunModeItem.EnableTun.Should().BeTrue();
    }
    private static readonly CoreSettings Core = new(true, "warning", "", null, null, null, null, null, null,
        0, 0, false, false, null, [], [], null);
    private static readonly InboundSettings Inbound = new(10808, false, true, true, [], false, false, false, null, null);
    private static readonly ApplicationSettings App = new(true, true, true, 12, null, null, null, null);
    private static SettingsEditValidator Validator() => new(new ServiceLibSettingsCapabilities());

    [Test]
    public async Task NullableAndZeroMuxUseSameValidationForSingleAndCombinedEdits()
    {
        foreach (var value in new int?[] { null, 0, 1024 })
        {
            var core = Core with { Mux4RayConcurrency = value, Mux4RayXudpConcurrency = value };
            await Validator().Validate(new(Core: core)).Should().BeEqualTo(SettingsValidationError.None);
            await Validator().Validate(new(Inbound: Inbound, Core: core, Application: App)).Should().BeEqualTo(SettingsValidationError.None);
        }
        foreach (var value in new[] { -1, 1025 })
            await Validator().Validate(new(Core: Core with { Mux4RayConcurrency = value })).Should().BeEqualTo(SettingsValidationError.CoreNumbers);
    }

    [Test]
    public async Task PortRangeAccountsForOnlyEnabledAdjacentListeners()
    {
        await SettingsPolicy.ValidPort(Inbound with { LocalPort = 65535 }).Should().BeTrue();
        await SettingsPolicy.ValidPort(Inbound with { LocalPort = 65535, NewPort4LAN = true }).Should().BeTrue();
        await SettingsPolicy.ValidPort(Inbound with { LocalPort = 65534, SecondLocalPortEnabled = true }).Should().BeFalse();
        await SettingsPolicy.ValidPort(Inbound with { LocalPort = 65533, SecondLocalPortEnabled = true }).Should().BeTrue();
        await SettingsPolicy.ValidPort(Inbound with { LocalPort = 65534, AllowLANConn = true, NewPort4LAN = true }).Should().BeFalse();
        await Validator().Validate(new(Inbound: Inbound with { AllowLANConn = true, NewPort4LAN = true, User = "user" }))
            .Should().BeEqualTo(SettingsValidationError.Credentials);
    }

    [Test]
    public async Task UpstreamSyntaxAndXrayOnlyMappingAreValidatedBeforeStorage()
    {
        await Validator().Validate(new(Inbound: Inbound with { DestOverride = ["http", "fakedns"] })).Should().BeEqualTo(SettingsValidationError.None);
        await Validator().Validate(new(Inbound: Inbound with { DestOverride = ["unknown"] })).Should().BeEqualTo(SettingsValidationError.SniffingProtocols);
        await Validator().Validate(new(Core: Core with { FragmentLengths = ["200-100"] })).Should().BeEqualTo(SettingsValidationError.Fragment);
        await Validator().Validate(new(CoreTypes: [new((int)EConfigType.VLESS, false)])).Should().BeEqualTo(SettingsValidationError.CoreTypes);
        await Validator().Validate(new(CoreTypes: [new(9999, true)])).Should().BeEqualTo(SettingsValidationError.CoreTypes);
        await Validator().Validate(new(CoreTypes: [new((int)EConfigType.VLESS, true), new((int)EConfigType.VLESS, true)]))
            .Should().BeEqualTo(SettingsValidationError.CoreTypes);
    }

    [Test]
    public async Task SingleSectionEditPreservesHiddenFieldsAndDoesNotAffectUnrelatedCoreSettings()
    {
        var scope = new Scope(); var store = new Store(scope); var effects = new Effects(scope, store);
        var coreBefore = ServiceLibSettingsEditor.Fingerprint(store.Current);
        var result = await Service(store, scope, effects).EditAsync(new(SpeedTest: new(20, "https://example.invalid/speed", "https://example.invalid/ping", 1, "", "target")));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.Saved);
        await result.CoreChanged.Should().BeFalse();
        await ServiceLibSettingsEditor.Fingerprint(store.Current).Should().BeEqualTo(coreBefore);
        await store.Current.SpeedTestItem.SpeedTestDelayInterval.Should().BeEqualTo(77);
        await store.Current.KcpItem.Mtu.Should().BeEqualTo(1408);
        await store.Current.Inbound[0].Protocol.Should().BeEqualTo("socks");
        await effects.Refreshes.Should().BeEqualTo(0);
    }

    [Test]
    public async Task CoreEditNormalizesWithoutReplacingUnexposedDocuments()
    {
        var scope = new Scope(); var store = new Store(scope); var effects = new Effects(scope, store);
        var originalTun = store.Current.TunModeItem;
        var result = await Service(store, scope, effects).EditAsync(new(Core: Core with { Mux4RayConcurrency = 0 }, Inbound: Inbound));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.Saved);
        await store.Current.Mux4RayItem.Concurrency.Should().BeNull();
        await store.Current.Inbound[0].DestOverride!.SequenceEqual(new InItem().DestOverride!).Should().BeTrue();
        await ReferenceEquals(originalTun, store.Current.TunModeItem).Should().BeTrue();
        await store.Current.TunModeItem.IPv4Address.Should().BeEqualTo("hidden-address");
        var repeat = await Service(store, scope, effects).EditAsync(new(Core: Core with { Mux4RayConcurrency = null }, Inbound: Inbound));
        await repeat.CoreChanged.Should().BeFalse();
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task FailedPersistenceCompensatesUnderSameMutationScopeAndNeverAppliesRuntime(bool failRestore)
    {
        var scope = new Scope(); var store = new Store(scope) { FailSave = true, FailRestore = failRestore }; var effects = new Effects(scope, store);
        var before = store.Disk;
        var result = await Service(store, scope, effects).EditAsync(new(Core: Core, Application: App), _ => throw new Exception("Runtime must not run"));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.PersistenceFailed);
        await result.ConfigRestored.Should().BeEqualTo(!failRestore);
        await store.Restores.Should().BeEqualTo(1);
        await effects.Refreshes.Should().BeEqualTo(0);
        await scope.Active.Should().BeFalse();
        if (!failRestore)
        {
            await store.Disk.Should().BeEqualTo(before);
            await JsonUtils.Serialize(store.Current).Should().BeEqualTo(before);
        }
        else await result.RollbackDetail.Should().BeEqualTo("restore failed");
    }

    [Test]
    public async Task StatisticsRefreshUsesFinalConfigAfterRuntimeRollbackOutsideMutationScope()
    {
        var scope = new Scope(); var store = new Store(scope); var effects = new Effects(scope, store);
        var result = await Service(store, scope, effects).EditAsync(new(Core: Core, Application: App), async changed =>
        {
            await scope.Active.Should().BeFalse();
            await changed.Should().BeTrue();
            await effects.Refreshes.Should().BeEqualTo(0);
            // Represents settings recovery restoring the snapshot before effects run.
            store.Current.GuiItem.EnableStatistics = false;
            store.Current.GuiItem.DisplayRealTimeSpeed = false;
            return false;
        });
        await result.Status.Should().BeEqualTo(SettingsEditStatus.RuntimeApplyFailed);
        await effects.Refreshes.Should().BeEqualTo(1);
        await effects.ObservedStatistics.Should().BeEqualTo(new StatisticsSelection(false, false));
    }

    [Test]
    public async Task StatisticsFailureDoesNotMisreportSuccessfulPersistence()
    {
        var scope = new Scope(); var store = new Store(scope); var effects = new Effects(scope, store) { FailRefresh = true };
        var result = await Service(store, scope, effects).EditAsync(new(Application: App));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.Saved);
        await store.Current.GuiItem.EnableStatistics.Should().BeTrue();
        await effects.Logs.Count.Should().BeEqualTo(1);
    }

    [Test]
    public async Task InvalidEditNeverCapturesAndCaptureFailureNeverWritesOrRestores()
    {
        var scope = new Scope(); var store = new Store(scope) { FailCapture = true }; var effects = new Effects(scope, store);
        var service = Service(store, scope, effects);
        await (await service.EditAsync(new(Inbound: Inbound with { LocalPort = 0 }))).Status.Should().BeEqualTo(SettingsEditStatus.Invalid);
        await store.Captures.Should().BeEqualTo(0);
        await (await service.EditAsync(new(Core: Core))).Status.Should().BeEqualTo(SettingsEditStatus.PersistenceFailed);
        await store.Saves.Should().BeEqualTo(0);
        await store.Restores.Should().BeEqualTo(0);
        await scope.Active.Should().BeFalse();
    }

    [Test]
    [Arguments(null, "original-secret")]
    [Arguments("", "")]
    [Arguments("  new password  ", "  new password  ")]
    public async Task WebDavEditNormalizesLocationAndPreservesOmittedPassword(string? password, string expected)
    {
        var scope = new Scope(); var store = new Store(scope); var effects = new Effects(scope, store);
        var result = await Service(store, scope, effects).EditAsync(new(WebDav: new(" https://example.test/ ", " user ", password, " backups ")));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.Saved);
        await result.CoreChanged.Should().BeFalse();
        await store.Current.WebDavItem.Url.Should().BeEqualTo("https://example.test/");
        await store.Current.WebDavItem.UserName.Should().BeEqualTo("user");
        await store.Current.WebDavItem.DirName.Should().BeEqualTo("backups");
        await store.Current.WebDavItem.Password.Should().BeEqualTo(expected);
        await store.Saves.Should().BeEqualTo(1);
        await effects.Refreshes.Should().BeEqualTo(0);
    }

    [Test]
    public async Task FailedWebDavSaveRestoresCredentialsAndCompleteConfiguration()
    {
        var scope = new Scope(); var store = new Store(scope) { FailSave = true }; var effects = new Effects(scope, store);
        var before = store.Disk;
        var result = await Service(store, scope, effects).EditAsync(new(WebDav: new("https://changed.test/", "new-user", "new-secret", "new-dir")));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.PersistenceFailed);
        await result.ConfigRestored.Should().BeTrue();
        await JsonUtils.Serialize(store.Current).Should().BeEqualTo(before);
        await store.Disk.Should().BeEqualTo(before);
    }

    private static SettingsEditorService Service(Store store, Scope scope, Effects effects) =>
        new(new ServiceLibSettingsEditor(store), scope, Validator(), effects);
    private sealed class Scope : IMutationScope
    {
        public bool Active;
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token = default)
        { if (Active) throw new Exception("Nested mutation"); Active = true; try { return await action(); } finally { Active = false; } }
    }
    private sealed class Effects(Scope scope, Store store) : ISettingsEditEffects
    {
        public int Refreshes;
        public bool FailRefresh;
        public StatisticsSelection? ObservedStatistics;
        public List<string> Logs = [];
        public Task RefreshStatisticsAsync()
        {
            if (scope.Active) throw new Exception("Effects inside mutation scope");
            Refreshes++;
            if (FailRefresh) throw new InvalidOperationException("stats failed");
            ObservedStatistics = new(store.Current.GuiItem.EnableStatistics, store.Current.GuiItem.DisplayRealTimeSpeed);
            return Task.CompletedTask;
        }
        public void Log(string message) => Logs.Add(message);
    }
    private sealed class Store : IRuntimeConfigStore
    {
        private readonly Scope _scope;
        public Store(Scope scope) { _scope = scope; Disk = JsonUtils.Serialize(Current); }
        public Config Current { get; } = new()
        {
            CoreBasicItem = new() { Loglevel = "warning", DefFingerprint = "" },
            Inbound = [new() { Protocol = "socks", LocalPort = 10808 }],
            TunModeItem = new() { Mtu = 1500, IPv4Address = "hidden-address" },
            KcpItem = new() { Mtu = 1408 }, GuiItem = new(), ConstItem = new(),
            Mux4RayItem = new(), HysteriaItem = new(), RoutingBasicItem = new() { DomainStrategy = "AsIs" },
            WebDavItem = new() { Password = "original-secret" },
            SimpleDNSItem = new(), CoreTypeItem = [], SpeedTestItem = new() { SpeedTestDelayInterval = 77 },
        };
        public string Disk;
        public bool FailSave, FailRestore, FailCapture;
        public int Captures, Saves, Restores;
        private void Check() { if (!_scope.Active) throw new Exception("Mutation required"); }
        public Task<int> SaveAsync()
        { Check(); Saves++; Disk = JsonUtils.Serialize(Current); return Task.FromResult(FailSave ? -1 : 0); }
        public Task<RuntimeConfigSnapshot> CaptureAsync()
        { Check(); Captures++; if (FailCapture) throw new InvalidOperationException("capture failed"); return Task.FromResult(new RuntimeConfigSnapshot(JsonUtils.DeepCopy(Current)!, [], [], [])); }
        public Task RestoreAsync(RuntimeConfigSnapshot snapshot)
        {
            Check(); Restores++; if (FailRestore) throw new InvalidOperationException("restore failed");
            ServiceLibRuntimeConfigStore.CopyValues(Current, snapshot.Config);
            Disk = JsonUtils.Serialize(Current); return Task.CompletedTask;
        }
        public Task RecoverPendingRestoreAsync() { Check(); return Task.CompletedTask; }
    }
}
