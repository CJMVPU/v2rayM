using ServiceLib.Models.Dto;
using ServiceLib.Services;

namespace v2rayN.WebAPI.Tests;

public class CoreReleaseSelectionTests
{
    private static GitHubRelease Release(string tag, bool prerelease = false) => new()
    {
        TagName = tag, Prerelease = prerelease, Assets = [new GitHubReleaseAsset { Name = "Xray-macos-arm64-v8a.zip" }]
    };

    [Test]
    public async Task PromotedStableReleaseDoesNotRegressToAnOlderPrerelease()
    {
        var releases = new[] { Release("v26.9.30", true), Release("v26.10.21"), Release("v26.9.9", true) };
        await CoreReleaseSelection.Select(releases, true)!.TagName.Should().BeEqualTo("v26.10.21");
    }

    [Test]
    public async Task NewerPrereleaseIsSelectedEvenWhenTheListIsUnsorted()
    {
        var releases = new[] { Release("v26.10.21"), Release("v26.9.30", true), Release("v26.10.22-beta.1", true) };
        await CoreReleaseSelection.Select(releases, true)!.TagName.Should().BeEqualTo("v26.10.22-beta.1");
        await CoreReleaseSelection.Select(releases, false)!.TagName.Should().BeEqualTo("v26.10.21");
    }

    [Test]
    public async Task DraftsMissingAssetsInvalidTagsAndVersionCapsAreRespected()
    {
        var draft = Release("v29.1.1"); draft.Draft = true;
        var empty = Release("v28.1.1"); empty.Assets = [];
        var releases = new[] { draft, empty, Release("not-a-version"), Release("v27.1.1", true), Release("v26.10.21") };
        await CoreReleaseSelection.Select(releases, true, new SemanticVersion("26.10.21"))!.TagName.Should().BeEqualTo("v26.10.21");
        await (CoreReleaseSelection.Select([draft, empty, Release("invalid")], true) is null).Should().BeTrue();
        await (CoreReleaseSelection.Select(null, true) is null).Should().BeTrue();
    }
}
