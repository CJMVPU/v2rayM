using System.Text.Json;
using ServiceLib.Common;
using ServiceLib.Models.Configs;
using v2rayN.WebAPI.Contracts;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class UpdatePreReleaseSettingsTests
{
    private const string WebTarget = "v2rayN.WebAPI";

    [Test]
    public async Task LegacyApiPreferencesMigrateWithoutChangingDesktopOrCorePreferences()
    {
        await (V2rayRuntime.NormalizeWebUpdateTargets(null) is null).Should().BeTrue();
        var migrated = V2rayRuntime.NormalizeWebUpdateTargets(["v2rayN", "Xray", "v2rayN.Web", WebTarget, "OtherPlatform"]);
        await migrated!.SequenceEqual(["v2rayN", "Xray", WebTarget, "OtherPlatform"]).Should().BeTrue();
        using var fixture = new RuntimeFixture();
        var result = await fixture.Runtime.SaveCoreUpdateSettingsAsync(new CoreUpdateSettingsInput(
            ["v2rayN.Web"], false, false, ["v2rayN.Web"]));
        await result.Success.Should().BeTrue();
        await fixture.Config.CheckUpdateItem.SelectedCoreTypes.SequenceEqual([WebTarget]).Should().BeTrue();
        await fixture.Config.CheckUpdateItem.CheckPreReleaseCoreTypes.SequenceEqual([WebTarget]).Should().BeTrue();
    }

    [Test]
    [Arguments(true, null, true)]
    [Arguments(false, null, false)]
    [Arguments(true, true, true)]
    [Arguments(true, false, false)]
    [Arguments(false, true, true)]
    [Arguments(false, false, false)]
    public async Task WebPreReleaseUsesItsOwnSettingUnlessExplicitlyOverridden(
        bool configured, bool? preRelease, bool expected)
    {
        using var fixture = new RuntimeFixture();
        fixture.Config.CheckUpdateItem.CheckPreReleaseCoreTypes = configured ? [WebTarget] : [];

        await fixture.Runtime.GetUpdatePreRelease(WebTarget, preRelease).Should().BeEqualTo(expected);
        // An override is request-scoped, not a change to persisted preferences.
        var settings = fixture.Runtime.GetCoreUpdateSettings();
        await settings.PreRelease.Should().BeEqualTo(configured);
        await settings.CheckPreReleaseCoreTypes.Contains(WebTarget).Should().BeEqualTo(configured);
    }

    [Test]
    public async Task NativeXrayIncludesPrereleasesEvenWithoutSavedPreference()
    {
        using var fixture = new RuntimeFixture();

        await fixture.Runtime.GetUpdatePreRelease(WebTarget).Should().BeFalse();
        await fixture.Runtime.GetUpdatePreRelease("Xray").Should().BeEqualTo(OperatingSystem.IsMacOS());
        await fixture.Runtime.GetUpdatePreRelease("Xray", false).Should().BeEqualTo(OperatingSystem.IsMacOS());
        await fixture.Runtime.GetCoreUpdateSettings().CheckPreReleaseCoreTypes.Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task WebPreReleaseIsIndependentOfDesktopAndCoreTargets()
    {
        using var fixture = new RuntimeFixture();
        fixture.Config.CheckUpdateItem.CheckPreReleaseCoreTypes = ["v2rayN", "Xray", "v2rayn.web"];

        await fixture.Runtime.GetUpdatePreRelease(WebTarget).Should().BeFalse();
        await fixture.Runtime.GetUpdatePreRelease("Xray").Should().BeTrue();
        var settings = fixture.Runtime.GetCoreUpdateSettings();
        await settings.PreRelease.Should().BeFalse();
        await settings.CheckPreReleaseCoreTypes.SequenceEqual(["Xray"]).Should().BeTrue();

        fixture.Config.CheckUpdateItem.CheckPreReleaseCoreTypes = [WebTarget];
        await fixture.Runtime.GetUpdatePreRelease(WebTarget).Should().BeTrue();
        await fixture.Runtime.GetUpdatePreRelease("Xray").Should().BeEqualTo(OperatingSystem.IsMacOS());
    }

    [Test]
    [Arguments(true)]
    [Arguments(false)]
    public async Task PerTargetSettingsSaveAddsOrRemovesWebAndPreservesHiddenPreferences(bool enableWeb)
    {
        using var fixture = new RuntimeFixture();
        fixture.Config.CheckUpdateItem.SelectedCoreTypes = ["v2rayN", "Xray", WebTarget];
        fixture.Config.CheckUpdateItem.CheckPreReleaseCoreTypes = ["v2rayN", "OtherPlatform", "Xray", WebTarget];
        var input = new CoreUpdateSettingsInput(
            ["Xray"], PreRelease: !enableWeb, UseProxy: false,
            CheckPreReleaseCoreTypes: enableWeb ? [WebTarget, WebTarget] : []);

        var result = await fixture.Runtime.SaveCoreUpdateSettingsAsync(input);

        await result.Success.Should().BeTrue();
        var saved = fixture.Config.CheckUpdateItem;
        await saved.CheckPreReleaseCoreTypes.Contains(WebTarget).Should().BeEqualTo(enableWeb);
        await saved.CheckPreReleaseCoreTypes.Contains("Xray").Should().BeFalse();
        await saved.CheckPreReleaseCoreTypes.Contains("v2rayN").Should().BeTrue();
        await saved.CheckPreReleaseCoreTypes.Contains("OtherPlatform").Should().BeTrue();
        await saved.CheckPreReleaseCoreTypes.Count(name => name == WebTarget).Should().BeEqualTo(enableWeb ? 1 : 0);
        // Prerelease preferences are saved even for targets not selected for a batch.
        await saved.SelectedCoreTypes.Contains(WebTarget).Should().BeFalse();
        await saved.SelectedCoreTypes.Contains("v2rayN").Should().BeTrue();
        await saved.UpdateViaProxy.Should().BeFalse();

        var view = fixture.Runtime.GetCoreUpdateSettings();
        await view.PreRelease.Should().BeEqualTo(enableWeb);
        await view.CheckPreReleaseCoreTypes.SequenceEqual(enableWeb ? [WebTarget] : []).Should().BeTrue();
        var reloaded = await fixture.ReadSavedConfigAsync();
        await reloaded.CheckUpdateItem.CheckPreReleaseCoreTypes.SequenceEqual(saved.CheckPreReleaseCoreTypes).Should().BeTrue();
    }

    [Test]
    [Arguments(true)]
    [Arguments(false)]
    public async Task LegacySettingsPayloadStillSavesSupportedTargetsIncludingWeb(bool preRelease)
    {
        using var fixture = new RuntimeFixture();
        fixture.Config.CheckUpdateItem.CheckPreReleaseCoreTypes = ["v2rayN", "Xray", WebTarget];
        var json = JsonSerializer.Serialize(new
        {
            selectedCoreTypes = Array.Empty<string>(),
            preRelease,
            useProxy = true,
        });
        var input = JsonSerializer.Deserialize<CoreUpdateSettingsInput>(json, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;

        await (input.CheckPreReleaseCoreTypes is null).Should().BeTrue();
        var result = await fixture.Runtime.SaveCoreUpdateSettingsAsync(input);

        await result.Success.Should().BeTrue();
        await fixture.Runtime.GetUpdatePreRelease(WebTarget).Should().BeEqualTo(preRelease);
        await fixture.Runtime.GetUpdatePreRelease("Xray").Should().BeEqualTo(OperatingSystem.IsMacOS() || preRelease);
        await fixture.Runtime.GetUpdatePreRelease("mihomo").Should().BeFalse();
        await fixture.Runtime.GetUpdatePreRelease("sing_box").Should().BeFalse();
        await fixture.Config.CheckUpdateItem.CheckPreReleaseCoreTypes.Contains("v2rayN").Should().BeTrue();
        var reloaded = await fixture.ReadSavedConfigAsync();
        await reloaded.CheckUpdateItem.CheckPreReleaseCoreTypes.Contains(WebTarget).Should().BeEqualTo(preRelease);
    }

    [Test]
    [Arguments("GeoFiles")]
    [Arguments("v2rayN")]
    [Arguments("hysteria2")]
    [Arguments("mihomo")]
    [Arguments("sing_box")]
    public async Task InvalidPerTargetPreReleaseSettingsDoNotMutateConfig(string target)
    {
        using var fixture = new RuntimeFixture();
        fixture.Config.CheckUpdateItem.CheckPreReleaseCoreTypes = [WebTarget];
        var previous = JsonUtils.Serialize(fixture.Config);

        var result = await fixture.Runtime.SaveCoreUpdateSettingsAsync(
            new CoreUpdateSettingsInput([], false, false, [target]));

        await result.Success.Should().BeFalse();
        await result.Code.Should().BeEqualTo("core_update_settings_invalid");
        await JsonUtils.Serialize(fixture.Config).Should().BeEqualTo(previous);
    }

    private sealed class RuntimeFixture : IDisposable, IRuntimeConfigStore
    {
        private string? _saved;
        public Config Config { get; } = new() { CheckUpdateItem = new CheckUpdateItem() };
        public Config Current => Config;
        public V2rayRuntime Runtime { get; }
        public RuntimeFixture() => Runtime = new(null!, null!, null!, null!, new RuntimeOperationCoordinator(), this);
        public Task<int> SaveAsync() { _saved = JsonUtils.Serialize(Config); return Task.FromResult(0); }
        public Task<RuntimeConfigSnapshot> CaptureAsync() => Task.FromResult(new RuntimeConfigSnapshot(
            JsonUtils.DeepCopy(Config)!, [], [], []));
        public Task RestoreAsync(RuntimeConfigSnapshot snapshot) => throw new NotSupportedException();
        public Task<Config> ReadSavedConfigAsync() => Task.FromResult(JsonUtils.Deserialize<Config>(_saved!)
            ?? throw new InvalidDataException("The saved update settings could not be reloaded."));
        public void Dispose() { }
    }
}
