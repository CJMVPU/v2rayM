using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using V2rayM.Application;
using V2rayM.Application.Settings;
using V2rayM.Domain.Settings;
using v2rayN.WebAPI.Adapters.Settings;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class ConfigurationProfileApplicationTests
{
    [Test]
    [Arguments(false, false, true)]
    [Arguments(false, true, false)]
    [Arguments(true, false, false)]
    [Arguments(true, true, true)]
    public async Task TemplateChangesAffectOnlyTheSelectedRuntimeMode(bool tun, bool editTun, bool changed)
    {
        var fixture = new Fixture(tun);
        var edit = ServiceLibConfigurationProfiles.Describe(fixture.Template);
        edit = editTun ? edit with { TunConfig = "new-tun" } : edit with { Config = "new-normal" };
        var result = await fixture.Service.EditAsync(new(CoreTemplate: edit));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.Saved);
        await result.CoreChanged.Should().BeEqualTo(changed);
        await fixture.Template.Id.Should().BeEqualTo("template-id");
        await fixture.Template.CoreType.Should().BeEqualTo(ECoreType.Xray);
        await fixture.Captured!.Templates.Single().TunConfig.Should().BeEqualTo("old-tun");
        await fixture.Captured.Templates.Single().Config.Should().BeEqualTo("old-normal");
        await fixture.ConfigWrites.Should().BeEqualTo(0);
    }

    [Test]
    [Arguments(false, false, true)]
    [Arguments(false, true, false)]
    [Arguments(true, false, false)]
    [Arguments(true, true, true)]
    public async Task DnsChangesAffectOnlyTheSelectedRuntimeMode(bool tun, bool editTun, bool changed)
    {
        var fixture = new Fixture(tun);
        var edit = ServiceLibConfigurationProfiles.Describe(fixture.Dns);
        edit = editTun ? edit with { TunDNS = "1.0.0.1" } : edit with { NormalDNS = "1.1.1.1" };
        var result = await fixture.Service.EditAsync(new(DnsProfile: edit with { Remarks = null }));
        await result.CoreChanged.Should().BeEqualTo(changed);
        await fixture.Dns.Id.Should().BeEqualTo("dns-id");
        await fixture.Dns.Remarks.Should().BeEqualTo("dns name");
        await fixture.Captured!.Dns.Single().NormalDNS.Should().BeEqualTo("8.8.8.8");
        await fixture.ConfigWrites.Should().BeEqualTo(0);
    }

    [Test]
    public async Task MetadataAndDisabledDocumentsDoNotTriggerRuntimeChanges()
    {
        var fixture = new Fixture(false);
        var renamed = await fixture.Service.EditAsync(new(
            DnsProfile: ServiceLibConfigurationProfiles.Describe(fixture.Dns) with { Remarks = "renamed dns" },
            CoreTemplate: ServiceLibConfigurationProfiles.Describe(fixture.Template) with { Remarks = "renamed template" }));
        await renamed.CoreChanged.Should().BeFalse();
        fixture.Dns.Enabled = false; fixture.Template.Enabled = false;
        var disabled = await fixture.Service.EditAsync(new(
            DnsProfile: ServiceLibConfigurationProfiles.Describe(fixture.Dns) with { NormalDNS = "9.9.9.9", UseSystemHosts = true },
            CoreTemplate: ServiceLibConfigurationProfiles.Describe(fixture.Template) with { Config = "new disabled", AddProxyOnly = true }));
        await disabled.CoreChanged.Should().BeFalse();
        var enabled = await fixture.Service.EditAsync(new(CoreTemplate: ServiceLibConfigurationProfiles.Describe(fixture.Template) with { Enabled = true }));
        await enabled.CoreChanged.Should().BeTrue();
    }

    [Test]
    public async Task EmptySelectedTemplateBypassesOptionsLikeTheGenerator()
    {
        var empty = new CoreTemplateSettings("name", true, null, "tun", false, null);
        await (empty.ForRuntime(false) is null).Should().BeTrue();
        await (empty with { Config = "", AddProxyOnly = true, ProxyDetour = "unused" }).ForRuntime(false).Should().BeNull();
        await empty.ForRuntime(true)!.Content.Should().BeEqualTo("tun");
        await (empty with { Enabled = false }).ForRuntime(true).Should().BeNull();
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task PartialProfileWriteFailureRestoresAllDocumentsBeforeRuntimeApply(bool restoreFails)
    {
        var fixture = new Fixture(false) { FailTemplate = true, FailRestore = restoreFails };
        var result = await fixture.Service.EditAsync(new(
            DnsProfile: ServiceLibConfigurationProfiles.Describe(fixture.Dns) with { NormalDNS = "9.9.9.9" },
            CoreTemplate: ServiceLibConfigurationProfiles.Describe(fixture.Template) with { Config = "edited" }),
            _ => throw new InvalidOperationException("Runtime apply must not run after persistence failure"));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.PersistenceFailed);
        await result.ConfigRestored.Should().BeEqualTo(!restoreFails);
        await fixture.ProfileWrites.Should().BeEqualTo(2);
        await fixture.Restores.Should().BeEqualTo(1);
        if (!restoreFails)
        {
            await fixture.Dns.NormalDNS.Should().BeEqualTo("8.8.8.8");
            await fixture.Template.Config.Should().BeEqualTo("old-normal");
        }
        else await result.RollbackDetail.Should().BeEqualTo("restore failed");
    }

    [Test]
    public async Task MissingProfileRejectsCombinedEditWithoutMutatingOtherConfiguration()
    {
        var fixture = new Fixture(false) { TemplateMissing = true };
        var result = await fixture.Service.EditAsync(new(
            SimpleDns: SettingsContractMapper.Map(fixture.Current.SimpleDNSItem) with { Hosts = "should not apply" },
            CoreTemplate: ServiceLibConfigurationProfiles.Describe(fixture.Template)));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.NotFound);
        await fixture.Current.SimpleDNSItem.Hosts.Should().NotBeEqualTo("should not apply");
        await fixture.ProfileWrites.Should().BeEqualTo(0);
        await fixture.ConfigWrites.Should().BeEqualTo(0);
        await fixture.Restores.Should().BeEqualTo(0);
    }

    [Test]
    public async Task SimpleDnsEditingRetainsTheStoredObjectAndAllAdvancedFields()
    {
        var fixture = new Fixture(false);
        var stored = fixture.Current.SimpleDNSItem;
        var input = SettingsContractMapper.Map(stored) with
        {
            UseSystemHosts = true, AddCommonHosts = false, ServeStale = true, ParallelQuery = true,
            Hosts = "custom.invalid 192.0.2.1", GlobalFakeIp = false, EnableHappyEyeballs = true,
            DirectExpectedIPs = "192.0.2.0/24",
        };
        var result = await fixture.Service.EditAsync(new(SimpleDns: input));
        await result.Status.Should().BeEqualTo(SettingsEditStatus.Saved);
        await result.CoreChanged.Should().BeTrue();
        await ReferenceEquals(stored, fixture.Current.SimpleDNSItem).Should().BeTrue();
        await SettingsContractMapper.Map(fixture.Current.SimpleDNSItem).Should().BeEqualTo(input);
        await fixture.ConfigWrites.Should().BeEqualTo(1);
        await fixture.ProfileWrites.Should().BeEqualTo(0);
    }

    [Test]
    public async Task InvalidDnsNeverCapturesOrTouchesStorage()
    {
        var fixture = new Fixture(false);
        var result = await fixture.Service.EditAsync(new(DnsProfile: ServiceLibConfigurationProfiles.Describe(fixture.Dns) with { TunDNS = "{broken" }));
        await result.Validation.Should().BeEqualTo(SettingsValidationError.DnsProfile);
        await fixture.Captured.Should().BeNull();
        await fixture.ProfileWrites.Should().BeEqualTo(0);
    }

    private sealed class Fixture : IRuntimeConfigStore, ISettingsProfileWriter, IMutationScope, ISettingsEditEffects
    {
        public Fixture(bool tun)
        {
            Current.TunModeItem.EnableTun = tun;
            Service = new(new ServiceLibSettingsEditor(this, this), this, new(new ServiceLibSettingsCapabilities()), this);
        }
        public Config Current { get; } = SniffingSettingsIntegrationTests.CreateConfig();
        public DNSItem Dns = new() { Id = "dns-id", Remarks = "dns name", CoreType = ECoreType.Xray, Enabled = true,
            NormalDNS = "8.8.8.8", TunDNS = "8.8.4.4", DomainStrategy4Freedom = "AsIs" };
        public FullConfigTemplateItem Template = new() { Id = "template-id", Remarks = "template name", CoreType = ECoreType.Xray,
            Enabled = true, Config = "old-normal", TunConfig = "old-tun", AddProxyOnly = false };
        public SettingsEditorService Service;
        public RuntimeConfigSnapshot? Captured;
        public bool FailTemplate, FailRestore, TemplateMissing;
        public int ConfigWrites, ProfileWrites, Restores;
        private bool _insideMutation;
        private void Check() { if (!_insideMutation) throw new InvalidOperationException("Mutation scope required"); }
        public Task<int> SaveAsync() { Check(); ConfigWrites++; return Task.FromResult(0); }
        public Task<RuntimeConfigSnapshot> CaptureAsync()
        {
            Check();
            Captured = new(JsonUtils.DeepCopy(Current)!, [], [JsonUtils.DeepCopy(Dns)!], TemplateMissing ? [] : [JsonUtils.DeepCopy(Template)!]);
            return Task.FromResult(Captured);
        }
        public Task RestoreAsync(RuntimeConfigSnapshot snapshot)
        {
            Check(); Restores++; if (FailRestore) throw new InvalidOperationException("restore failed");
            ServiceLibRuntimeConfigStore.CopyValues(Current, snapshot.Config);
            Dns = JsonUtils.DeepCopy(snapshot.Dns.Single())!;
            Template = JsonUtils.DeepCopy(snapshot.Templates.Single())!;
            return Task.CompletedTask;
        }
        public Task RecoverPendingRestoreAsync() { Check(); return Task.CompletedTask; }
        public Task<bool> SaveDnsAsync(DNSItem item) { Check(); ProfileWrites++; Dns = JsonUtils.DeepCopy(item)!; return Task.FromResult(true); }
        public Task<bool> SaveTemplateAsync(FullConfigTemplateItem item)
        { Check(); ProfileWrites++; if (!FailTemplate) Template = JsonUtils.DeepCopy(item)!; return Task.FromResult(!FailTemplate); }
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token = default)
        {
            if (_insideMutation) throw new InvalidOperationException("Nested mutation");
            _insideMutation = true; try { return await action(); } finally { _insideMutation = false; }
        }
        public Task RefreshStatisticsAsync() => throw new InvalidOperationException("Profile edits must not refresh statistics");
        public void Log(string message) { }
    }
}
