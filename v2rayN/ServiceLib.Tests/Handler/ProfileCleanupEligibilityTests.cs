using ServiceLib.Tests.CoreConfig;

namespace ServiceLib.Tests.Handler;

[NotInParallel]
public class ProfileCleanupEligibilityTests
{
    [Test]
    public async Task DeduplicationPreservesExcludedRowsAndDoesNotUseThemAsDuplicateAnchors()
    {
        var config = CoreConfigTestFactory.CreateConfig();
        CoreConfigTestFactory.BindAppManagerConfig(config);
        config.GuiItem.KeepOlderDedupl = true;
        TestDatabase.Initialize();
        var group = "cleanup-" + Guid.NewGuid().ToString("N");
        var rows = new[] { "unsupported", "first", "duplicate" }.Select(suffix => new ProfileItem
        {
            IndexId = group + suffix, Subid = group, ConfigType = EConfigType.SOCKS,
            CoreType = suffix == "unsupported" ? (ECoreType)999 : ECoreType.Xray,
            Remarks = suffix, Address = "127.0.0.1", Port = 1080,
        }).ToArray();
        try
        {
            foreach (var row in rows) await SQLiteHelper.Instance.ReplaceAsync(row);
            var result = await ConfigDbHandler.DedupServerList(config, group, XrayOnlyPolicy.Supports);
            await (result.Item1 - result.Item2).Should().BeEqualTo(1);
            var remaining = await ConfigDbQuery.ProfileItems(group);
            await remaining!.Count.Should().BeEqualTo(2);
            await remaining.Any(item => item.IndexId == group + "unsupported").Should().BeTrue();
            await remaining.Count(XrayOnlyPolicy.Supports).Should().BeEqualTo(1);
        }
        finally { foreach (var row in rows) await SQLiteHelper.Instance.DeleteAsync(row); }
    }
}
