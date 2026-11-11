namespace ServiceLib.Tests.CoreConfig.V2ray;

public class XrayUdpHopTests
{
    [Test]
    public async Task HysteriaHopUsesFinalmaskAndPreservesSalamanderOrder()
    {
        var config = CoreConfigTestFactory.CreateConfig();
        CoreConfigTestFactory.BindAppManagerConfig(config);
        var node = CoreConfigTestFactory.CreateVmessNode(ECoreType.Xray);
        node.ConfigType = EConfigType.Hysteria2;
        node.Password = "test-password";
        node.StreamSecurity = Global.StreamSecurity;
        node.SetProtocolExtra(node.GetProtocolExtra() with
        {
            SalamanderPass = "test-mask", Ports = "10000:10010", HopInterval = "15",
        });
        var result = new CoreConfigV2rayService(CoreConfigTestFactory.CreateContext(config, node, ECoreType.Xray))
            .GenerateClientConfigContent();
        await result.Success.Should().BeTrue();
        var root = JsonNode.Parse(result.Data!.ToString()!)!;
        var proxy = root["outbounds"]!.AsArray().First(x => x!["tag"]!.GetValue<string>() == Global.ProxyTag)!;
        var mask = proxy["streamSettings"]!["finalmask"]!;
        await mask["quicParams"]!.AsObject().ContainsKey("udpHop").Should().BeFalse();
        var udp = mask["udp"]!.AsArray();
        await udp.Count.Should().BeEqualTo(2);
        await udp[0]!["type"]!.GetValue<string>().Should().BeEqualTo("salamander");
        await udp[1]!["type"]!.GetValue<string>().Should().BeEqualTo("udphop");
        await udp[1]!["settings"]!["remotePorts"]!.GetValue<string>().Should().BeEqualTo("10000-10010");
        await udp[1]!["settings"]!["mode"]!.GetValue<string>().Should().BeEqualTo("intervallocal,intervalremote");
    }
}
