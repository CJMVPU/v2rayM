using ServiceLib.Tests.CoreConfig;

namespace ServiceLib.Tests.Handler;

[NotInParallel]
public class ConfigHandlerCustomSubscriptionTests
{
    [Test]
    public async Task InvalidSubscriptionRetainsExistingRowsAndCustomFiles()
    {
        var config = CoreConfigTestFactory.CreateConfig();
        CoreConfigTestFactory.BindAppManagerConfig(config);
        SQLiteHelper.Instance.CreateTable<SubItem>();
        SQLiteHelper.Instance.CreateTable<ProfileItem>();
        var subId = $"invalid-sub-{Guid.NewGuid():N}";
        var fileName = $"retained-{Guid.NewGuid():N}.json";
        var path = Utils.GetConfigPath(fileName);
        try
        {
            await File.WriteAllTextAsync(path, "original custom config");
            await SQLiteHelper.Instance.ReplaceAsync(new SubItem { Id = subId, Remarks = "sub" });
            await SQLiteHelper.Instance.ReplaceAsync(new ProfileItem
                { IndexId = subId + "-old", Subid = subId, IsSub = true, ConfigType = EConfigType.Custom, CoreType = ECoreType.Xray, Address = fileName });
            var count = await ConfigHandler.AddBatchServers(config, "<html><body>upstream unavailable</body></html>", subId, true);
            await (count <= 0).Should().BeTrue();
            await (await AppManager.Instance.ProfileItems(subId))!.Count.Should().BeEqualTo(1);
            await File.Exists(path).Should().BeTrue();
        }
        finally { File.Delete(path); }
    }

    [Test]
    public async Task SuccessfulSubscriptionReplacementRetainsManualAndUnsupportedStoredRows()
    {
        var config = CoreConfigTestFactory.CreateConfig();
        CoreConfigTestFactory.BindAppManagerConfig(config);
        SQLiteHelper.Instance.CreateTable<SubItem>();
        SQLiteHelper.Instance.CreateTable<ProfileItem>();
        var subId = $"replace-sub-{Guid.NewGuid():N}";
        var fileName = $"manual-{Guid.NewGuid():N}.json";
        var path = Utils.GetConfigPath(fileName);
        try
        {
            await File.WriteAllTextAsync(path, "manual config");
            await SQLiteHelper.Instance.ReplaceAsync(new SubItem { Id = subId, Remarks = "sub" });
            await SQLiteHelper.Instance.InsertAllAsync(new[]
            {
                new ProfileItem { IndexId = subId + "-old", Subid = subId, IsSub = true, ConfigType = EConfigType.VLESS, CoreType = ECoreType.Xray },
                new ProfileItem { IndexId = subId + "-unsupported", Subid = subId, IsSub = true, ConfigType = EConfigType.Custom, CoreType = ECoreType.mihomo },
                new ProfileItem { IndexId = subId + "-manual", Subid = subId, IsSub = false, ConfigType = EConfigType.Custom, CoreType = ECoreType.Xray, Address = fileName },
            });
            var count = await ConfigHandler.AddBatchServers(config,
                "vless://00000000-0000-0000-0000-000000000001@127.0.0.1:443?encryption=none#replacement\nnot-a-valid-node", subId, true);
            await count.Should().BeEqualTo(1);
            var profiles = (await AppManager.Instance.ProfileItems(subId))!;
            await profiles.Count.Should().BeEqualTo(3);
            await profiles.Any(item => item.IndexId == subId + "-unsupported").Should().BeTrue();
            await profiles.Any(item => item.IndexId == subId + "-manual").Should().BeTrue();
            await profiles.Any(item => item.IndexId == subId + "-old").Should().BeFalse();
            await File.Exists(path).Should().BeTrue();
        }
        finally { File.Delete(path); }
    }

    [Test]
    public async Task InnerReplacementRemapsOldIdAndMigratesActiveSelectionAndTrafficOnlyToNewRows()
    {
        var config = CoreConfigTestFactory.CreateConfig();
        CoreConfigTestFactory.BindAppManagerConfig(config);
        SQLiteHelper.Instance.CreateTable<SubItem>(); SQLiteHelper.Instance.CreateTable<ProfileItem>();
        SQLiteHelper.Instance.CreateTable<ServerStatItem>();
        var subId = $"identity-sub-{Guid.NewGuid():N}";
        await SQLiteHelper.Instance.ReplaceAsync(new SubItem { Id = subId, Remarks = "sub" });
        var old = CoreConfigTestFactory.CreateSocksNode(ECoreType.Xray, subId + "-old", "same endpoint");
        old.Subid = subId; old.IsSub = true;
        var manual = JsonUtils.DeepCopy(old)!;
        manual.IndexId = subId + "-manual"; manual.IsSub = false;
        await SQLiteHelper.Instance.InsertAllAsync(new[] { old, manual });
        config.IndexId = old.IndexId;
        var manager = StatisticsManager.Instance;
        var type = typeof(StatisticsManager);
        var gate = type.GetField("_gate", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(manager)!;
        lock (gate)
        {
            var stats = (List<ServerStatItem>)type.GetField("_lstServerStat", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(manager)!;
            stats.Add(new ServerStatItem { IndexId = old.IndexId, TotalUp = 77 });
            stats.Add(new ServerStatItem { IndexId = manual.IndexId, TotalUp = 200 });
        }
        var count = await ConfigHandler.AddBatchServers(config, InnerFmt.ToUri([old])!, subId, true);
        await count.Should().BeEqualTo(1);
        var current = (await AppManager.Instance.ProfileItems(subId))!;
        var imported = current.Single(item => item.IsSub);
        await (imported.IndexId != old.IndexId).Should().BeTrue();
        await config.IndexId.Should().BeEqualTo(imported.IndexId);
        var saved = await SQLiteHelper.Instance.TableAsync<ServerStatItem>().ToListAsync();
        await saved.Single(item => item.IndexId == imported.IndexId).TotalUp.Should().BeEqualTo(77L);
        await saved.Single(item => item.IndexId == manual.IndexId).TotalUp.Should().BeEqualTo(200L);
    }

    [Test]
    public async Task FailedReplacementWriteDoesNotDeleteTheOldSubscription()
    {
        var config = CoreConfigTestFactory.CreateConfig();
        CoreConfigTestFactory.BindAppManagerConfig(config);
        SQLiteHelper.Instance.CreateTable<SubItem>(); SQLiteHelper.Instance.CreateTable<ProfileItem>();
        var subId = $"failure-sub-{Guid.NewGuid():N}";
        var trigger = "reject_" + Guid.NewGuid().ToString("N");
        await SQLiteHelper.Instance.ReplaceAsync(new SubItem { Id = subId, Remarks = "sub" });
        await SQLiteHelper.Instance.ReplaceAsync(new ProfileItem
            { IndexId = subId + "-old", Subid = subId, IsSub = true, ConfigType = EConfigType.VLESS });
        await SQLiteHelper.Instance.ExecuteAsync($"CREATE TRIGGER {trigger} BEFORE INSERT ON ProfileItem WHEN NEW.Subid = '{subId}' BEGIN SELECT RAISE(ABORT, 'injected'); END");
        try
        {
            var failed = false;
            try
            {
                await ConfigHandler.AddBatchServers(config,
                    "vless://00000000-0000-0000-0000-000000000001@127.0.0.1:443?encryption=none#replacement", subId, true);
            }
            catch (SQLiteException) { failed = true; }
            await failed.Should().BeTrue();
            await (await AppManager.Instance.ProfileItems(subId))!.Single().IndexId.Should().BeEqualTo(subId + "-old");
        }
        finally { await SQLiteHelper.Instance.ExecuteAsync($"DROP TRIGGER {trigger}"); }
    }

    [Test]
    public async Task ReplacedCustomFileIsRetainedWhileAnotherNodeReferencesIt()
    {
        var config = CoreConfigTestFactory.CreateConfig();
        CoreConfigTestFactory.BindAppManagerConfig(config);
        SQLiteHelper.Instance.CreateTable<SubItem>(); SQLiteHelper.Instance.CreateTable<ProfileItem>();
        var subId = $"shared-sub-{Guid.NewGuid():N}";
        var fileName = $"shared-{Guid.NewGuid():N}.json";
        var path = Utils.GetConfigPath(fileName);
        try
        {
            await File.WriteAllTextAsync(path, "shared config");
            await SQLiteHelper.Instance.ReplaceAsync(new SubItem { Id = subId, Remarks = "sub" });
            await SQLiteHelper.Instance.InsertAllAsync(new[]
            {
                new ProfileItem { IndexId = subId + "-old", Subid = subId, IsSub = true, ConfigType = EConfigType.Custom, Address = fileName },
                new ProfileItem { IndexId = subId + "-manual", Subid = subId, IsSub = false, ConfigType = EConfigType.Custom, Address = fileName },
            });
            var count = await ConfigHandler.AddBatchServers(config,
                "vless://00000000-0000-0000-0000-000000000001@127.0.0.1:443?encryption=none#replacement", subId, true);
            await count.Should().BeEqualTo(1);
            await File.Exists(path).Should().BeTrue();
        }
        finally { File.Delete(path); }
    }

    [Test]
    public async Task SubscriptionOnlyRemovalDoesNotDeleteManualCustomFiles()
    {
        var config = CoreConfigTestFactory.CreateConfig();
        SQLiteHelper.Instance.CreateTable<ProfileItem>();
        var subId = $"remove-sub-{Guid.NewGuid():N}";
        var fileName = $"manual-direct-{Guid.NewGuid():N}.json";
        var path = Utils.GetConfigPath(fileName);
        try
        {
            await File.WriteAllTextAsync(path, "manual config");
            await SQLiteHelper.Instance.InsertAllAsync(new[]
            {
                new ProfileItem { IndexId = subId + "-old", Subid = subId, IsSub = true, ConfigType = EConfigType.VLESS },
                new ProfileItem { IndexId = subId + "-manual", Subid = subId, IsSub = false, ConfigType = EConfigType.Custom, Address = fileName },
            });
            await ConfigHandler.RemoveServersViaSubid(config, subId, true);
            await (await AppManager.Instance.ProfileItems(subId))!.Single().IndexId.Should().BeEqualTo(subId + "-manual");
            await File.Exists(path).Should().BeTrue();
        }
        finally { File.Delete(path); }
    }

    private const string FullXrayConfigs = """
        [
          {"remarks":"custom-1","inbounds":[{"tag":"socks","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"auth":"noauth","udp":true}}],"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":443,"users":[{"id":"00000000-0000-0000-0000-000000000001","encryption":"none"}]}]},"streamSettings":{"network":"tcp"}}],"routing":{"domainStrategy":"AsIs","rules":[]}},
          {"remarks":"custom-2","inbounds":[{"tag":"socks","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"auth":"noauth","udp":true}}],"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":443,"users":[{"id":"00000000-0000-0000-0000-000000000001","encryption":"none"}]}]},"streamSettings":{"network":"tcp"}}],"routing":{"domainStrategy":"AsIs","rules":[]}}
        ]
        """;

    [Test]
    public async Task AddBatchServers_FullConfigsFromSubscription_InheritSubscriptionPreSocksPort()
    {
        var config = CoreConfigTestFactory.CreateConfig();
        CoreConfigTestFactory.BindAppManagerConfig(config);
        SQLiteHelper.Instance.CreateTable<SubItem>();
        SQLiteHelper.Instance.CreateTable<ProfileItem>();

        var subId = $"sub-{Guid.NewGuid():N}";
        await SQLiteHelper.Instance.ReplaceAsync(new SubItem
        {
            Id = subId,
            Remarks = "sub",
            Url = "http://127.0.0.1/sub",
            PreSocksPort = 10808,
        });

        var count = await ConfigHandler.AddBatchServers(config, FullXrayConfigs, subId, true);
        var profiles = await AppManager.Instance.ProfileItems(subId) ?? [];

        await count.Should().BeEqualTo(2);
        await profiles.Should().HaveCount(2);
        foreach (var profile in profiles)
        {
            await profile.ConfigType.Should().BeEqualTo(EConfigType.Custom);
            await profile.PreSocksPort.Should().BeEqualTo(10808);
        }
    }
}
