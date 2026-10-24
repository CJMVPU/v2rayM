using ServiceLib.Models.Dto;

namespace v2rayN.WebAPI.Tests;

public class StrictSemanticVersionTests
{
    [Test]
    public async Task ReleaseParsingRejectsMalformedAndOverflowingInputWithoutChangingLegacyConstructor()
    {
        foreach (var value in new string?[] { null, "", "invalid", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1.2.3-01", "1.2.3-a..b", "1.2.3+", "1.2.3\n", " 1.2.3", "2147483648.0.0", "1.2.3-β" })
        {
            await SemanticVersion.TryParse(value, out var parsed).Should().BeFalse();
            await (parsed is null).Should().BeTrue();
        }
        foreach (var value in new[] { "0.0.0", "v26.10.21", "V1.2.3-beta.2+build.001", "1.2.3-999999999999999999999" })
            await SemanticVersion.TryParse(value, out _).Should().BeTrue();
        await new SemanticVersion("1.2").ToStandardVersionString().Should().BeEqualTo("1.2.0");
    }

    [Test]
    public async Task ArbitrarilyLargeNumericPrereleaseIdentifiersKeepSemanticOrdering()
    {
        SemanticVersion.TryParse("1.2.3-999999999999999999999", out var first);
        SemanticVersion.TryParse("1.2.3-1000000000000000000000", out var second);
        SemanticVersion.TryParse("1.2.3-alpha", out var text);
        await (first! < second!).Should().BeTrue();
        await (second! < text!).Should().BeTrue();
    }
}
