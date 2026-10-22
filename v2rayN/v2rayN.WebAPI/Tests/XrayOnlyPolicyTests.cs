using ServiceLib.Enums;
using ServiceLib.Handler.Builder;
using ServiceLib.Manager;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Services;
namespace v2rayN.WebAPI.Tests;
public class XrayOnlyPolicyTests
{
    [Test]
    public async Task RetiredEnginesCannotReachCustomOrGroupConfiguration()
    {
        foreach (var engine in new[] { (ECoreType)24, ECoreType.mihomo, ECoreType.v2fly })
        foreach (var type in new[] { EConfigType.Custom, EConfigType.Outbound, EConfigType.PolicyGroup, EConfigType.VLESS })
        {
            var profile = new ProfileItem { CoreType = engine, ConfigType = type };
            await XrayOnlyPolicy.Supports(profile).Should().BeFalse();
            await NodeValidator.Validate(profile, engine).Success.Should().BeFalse();
            await (CoreInfoManager.Instance.GetCoreInfo(engine) is null).Should().BeTrue();
            await CoreUpdatePackageStager.SupportsCore(engine).Should().BeFalse();
        }
    }
    [Test]
    public async Task UnsupportedProtocolsDoNotBecomeXrayNodes()
    {
        foreach (var type in new[] { EConfigType.TUIC, EConfigType.Anytls, EConfigType.Naive })
            await XrayOnlyPolicy.Supports(new ProfileItem { ConfigType = type }).Should().BeFalse();
        await XrayOnlyPolicy.Supports(new ProfileItem { ConfigType = EConfigType.VLESS }).Should().BeTrue();
    }
}
