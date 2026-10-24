using ServiceLib.Models.Dto;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class RepairedCoreUpdateTests
{
    private static readonly XrayBuildIdentity Installed = new("26.10.21", "darwin-bind2");
    private static UpdateResult Release(string tag) => new(true, new SemanticVersion(tag))
    { ReleaseTag = tag, Url = "https://github.com/XTLS/Xray-core/releases/download/fixture/xray.zip" };

    [Test]
    public async Task SameUpstreamReleaseSkipsDownloadWithoutCallingItAnError()
    {
        var result = Release("v26.10.21");
        await NativeTunCoreCompatibility.ApplyUpdatePolicy(Installed, result).Should().BeEqualTo(true);
        await result.Msg.Should().BeEqualTo("已安装同版本修复版，无需更新");
        await (result.Url == null).Should().BeTrue();
        await result.Success.Should().BeFalse(); // Not available; wrapper marks IsUpToDate.
        await result.AwaitingCompatibilityValidation.Should().BeFalse();
    }

    [Test]
    public async Task FutureStableAndPrereleaseRequireCompatibilityReview()
    {
        foreach (var tag in new[] { "v26.10.22", "v26.10.22-beta.1", "v27.1.1" })
        {
            var result = Release(tag);
            await NativeTunCoreCompatibility.ApplyUpdatePolicy(Installed, result).Should().BeEqualTo(false);
            await result.Msg!.Contains("等待验证后再替换内核").Should().BeTrue();
            await result.AwaitingCompatibilityValidation.Should().BeTrue();
            await result.ReleaseTag.Should().BeEqualTo(tag);
            await (result.Url == null).Should().BeTrue();
        }
    }

    [Test]
    public async Task UnknownInstalledVersionCannotAuthorizeAReplacement()
    {
        var result = Release("v26.10.22");
        await NativeTunCoreCompatibility.ApplyUpdatePolicy(null, result).Should().BeEqualTo(false);
        await result.AwaitingCompatibilityValidation.Should().BeTrue();
        await (result.Url == null).Should().BeTrue();
    }

    [Test]
    public async Task OlderReleaseCannotDowngradeAndOriginalTagSurvivesStoreSynchronization()
    {
        var result = Release("v26.10.20");
        result.Version = new SemanticVersion("26.10.21");
        await NativeTunCoreCompatibility.ApplyUpdatePolicy(Installed, result).Should().BeEqualTo(true);
        await result.Msg.Should().BeEqualTo("已安装较新修复版，无需更新");
    }

    [Test]
    public async Task OfficialInstallsAlsoWaitForValidationWhileApiFailuresRemainFailures()
    {
        var official = Release("v26.10.22");
        await NativeTunCoreCompatibility.ApplyUpdatePolicy(new("26.10.21", null), official).Should().BeEqualTo(false);
        await official.Success.Should().BeFalse();
        await official.AwaitingCompatibilityValidation.Should().BeTrue();
        await (official.Url == null).Should().BeTrue();
        var failure = new UpdateResult(false, "release API unavailable");
        await (NativeTunCoreCompatibility.ApplyUpdatePolicy(Installed, failure) == null).Should().BeTrue();
        await failure.Msg.Should().BeEqualTo("release API unavailable");
        await failure.AwaitingCompatibilityValidation.Should().BeFalse();
    }
}
