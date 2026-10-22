using ServiceLib.Enums;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class BuiltinDnsProfileBootstrapTests
{
    [Test]
    public async Task EmptyDnsTableGetsExactlyOneDisabledXrayProfile()
    {
        var result = await Ensure([]);
        await result.Rows.Count(item => item.CoreType == ECoreType.Xray).Should().BeEqualTo(1);
        await result.SavedTypes.Count.Should().BeEqualTo(1);
        await result.Rows.All(item => !item.Enabled).Should().BeTrue();
        await result.Rows.Single(item => item.CoreType == ECoreType.Xray).Remarks.Should().BeEqualTo("V2ray");
        await result.Rows.Count.Should().BeEqualTo(1);
    }

    [Test]
    public async Task XrayOnlyStateIsUnchanged()
    {
        var xray = Existing(ECoreType.Xray, "xray-id", "preserved xray", enabled: true);
        var result = await Ensure([xray]);
        await result.Rows.Count(item => item.CoreType == ECoreType.Xray).Should().BeEqualTo(1);
        await (result.Rows.Single(item => item.CoreType == ECoreType.Xray) == xray).Should().BeTrue();
        await result.SavedTypes.Count.Should().BeEqualTo(0);
        await (xray.Remarks == "preserved xray" && xray.Enabled).Should().BeTrue();
        await result.Rows.Count.Should().BeEqualTo(1);
    }

    [Test]
    public async Task LegacyRowsArePreservedWhileAddingXray()
    {
        var singbox = Existing((ECoreType)24, "singbox-id", "preserved sing-box", enabled: true);
        var result = await Ensure([singbox]);
        await result.Rows.Count(item => item.CoreType == ECoreType.Xray).Should().BeEqualTo(1);
        await (result.Rows.Single(item => item.CoreType == (ECoreType)24) == singbox).Should().BeTrue();
        await result.SavedTypes.SequenceEqual(new[] { ECoreType.Xray }).Should().BeTrue();
        await (singbox.Remarks == "preserved sing-box" && singbox.Enabled).Should().BeTrue();
        var xray = result.Rows.Single(item => item.CoreType == ECoreType.Xray);
        await (!xray.Enabled && xray.Remarks == "V2ray").Should().BeTrue();
    }

    [Test]
    public async Task CompleteDnsStateIsLeftUntouched()
    {
        var xray = Existing(ECoreType.Xray, "xray-id", "custom xray", enabled: true);
        var singbox = Existing((ECoreType)24, "singbox-id", "custom sing-box", enabled: true);
        var result = await Ensure([xray, singbox]);
        await result.Rows.Count(item => item.CoreType == ECoreType.Xray).Should().BeEqualTo(1);
        await result.SavedTypes.Count.Should().BeEqualTo(0);
        await (result.Rows[0] == xray && result.Rows[1] == singbox).Should().BeTrue();
    }

    private static async Task<(List<DNSItem> Rows, List<ECoreType> SavedTypes)> Ensure(List<DNSItem> initial)
    {
        var rows = new List<DNSItem>(initial);
        var savedTypes = new List<ECoreType>();
        await BuiltinDnsProfileBootstrap.EnsureAsync(
            new Config(),
            () => Task.FromResult<IReadOnlyList<DNSItem>>(rows.ToArray()),
            (_, item) =>
            {
                rows.Add(item);
                savedTypes.Add(item.CoreType);
                return Task.FromResult(0);
            });
        return (rows, savedTypes);
    }

    private static DNSItem Existing(ECoreType coreType, string id, string remarks, bool enabled) => new()
    {
        Id = id,
        CoreType = coreType,
        Remarks = remarks,
        Enabled = enabled,
        NormalDNS = "user DNS data",
    };
}
