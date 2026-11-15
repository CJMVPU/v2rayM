using V2rayM.Domain.Runtime;
using V2rayM.Domain.Updates;
using ServiceLib.Models.Dto;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class DomainBoundaryTests
{
    [Test]
    public async Task DomainAssemblyHasNoUpstreamOrWebDependencies()
    {
        var references = typeof(CoreSettingsApplyPolicy).Assembly.GetReferencedAssemblies();
        await references.All(reference => reference.Name is "System.Runtime" or "System.Collections" or "System.Linq" or "System.Threading").Should().BeTrue();
    }

    [Test]
    public async Task UnknownUpstreamDecisionCannotAuthorizeStaging()
    {
        var result = new UpdateResult(true, (string?)null)
        {
            Decision = (UpdateCheckDecision)999,
            Version = new SemanticVersion("26.11.9"),
            Url = "https://example.invalid/xray.zip",
        };
        await ModuleUpdateCoordinator.Classify(result, false).Decision.Should().BeEqualTo(UpdateCheckDecision.Failed);
    }

    [Test]
    public async Task CompatibilityHoldIsAuthoritativeForEveryCandidateShape()
    {
        foreach (var success in new[] { true, false })
        foreach (var version in new[] { true, false })
        foreach (var download in new[] { true, false })
            await UpdateAdmission.Decide(UpdateDecision.AwaitingValidation, false, success, version, download)
                .Should().BeEqualTo(UpdateDecision.AwaitingValidation);
    }

    [Test]
    public async Task ReversedSampleTimeResetsWindowAndAcceptsANewGeneration()
    {
        var window = new V2rayM.Domain.Telemetry.TrafficAverageWindow();
        var now = DateTimeOffset.UtcNow;
        window.Add(new(10, 20, 30, 40, 5, now));
        window.Add(new(10, 20, 30, 40, 5, now.AddSeconds(-1)));
        await (window.Read(now) is null).Should().BeTrue();
        window.Add(new(1, 2, 3, 4, 5, now));
        await window.Read(now)!.ProxyUp.Should().BeEqualTo(1);
        window.Clear();
        window.Add(new(2, 3, 4, 5, 5, now.AddSeconds(-10)));
        await window.Read(now.AddSeconds(-10))!.ProxyUp.Should().BeEqualTo(2);
    }
}
