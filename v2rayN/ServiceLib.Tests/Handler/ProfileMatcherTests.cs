namespace ServiceLib.Tests.Handler;

public class ProfileMatcherTests
{
    [Test]
    public async Task SubscriptionMatchingPrefersFullIdentityOverAnEarlierMatchingName()
    {
        var renamedAddress = new ProfileItem { ConfigType = EConfigType.VLESS, Remarks = "node", Address = "other.example", Port = 443 };
        var exact = new ProfileItem { ConfigType = EConfigType.VLESS, Remarks = "node", Address = "proxy.example", Port = 443 };
        var target = new ProfileItem { ConfigType = EConfigType.VLESS, Remarks = "node", Address = "proxy.example", Port = 443 };
        await ReferenceEquals(Match([renamedAddress, exact], target), exact).Should().BeTrue();
    }

    [Test]
    public async Task SubscriptionMatchingRetainsAddressFallbackAndDoesNotMatchMissingIdentity()
    {
        var original = new ProfileItem { ConfigType = EConfigType.VLESS, Remarks = "old", Address = "Proxy.Example", Port = 443, Password = "old" };
        var changed = new ProfileItem { ConfigType = EConfigType.VLESS, Remarks = "new", Address = " proxy.example ", Port = 443, Password = "new" };
        await ReferenceEquals(Match([original], changed), original).Should().BeTrue();
        await (Match([original], new ProfileItem()) is null).Should().BeTrue();
    }

    private static ProfileItem? Match(IEnumerable<ProfileItem> items, ProfileItem target) =>
        (ProfileItem?)typeof(ConfigDbHandler).GetMethod("FindMatchedProfileItem", BindingFlags.Static | BindingFlags.NonPublic)!
            .Invoke(null, [items, target]);
}
