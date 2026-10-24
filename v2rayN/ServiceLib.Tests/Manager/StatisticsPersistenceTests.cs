namespace ServiceLib.Tests.Manager;

public class StatisticsPersistenceTests
{
    [Test]
    public async Task ReloadingStatisticsKeepsCurrentNodeBoundToPersistedRecords()
    {
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-statistics-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var db = new SQLiteHelper(Path.Combine(directory, "test.db"));
        try
        {
            db.CreateTable<ProfileItem>(); db.CreateTable<ServerStatItem>();
            await db.InsertAsync(new ProfileItem { IndexId = "node" });
            var manager = new StatisticsManager(db);
            var type = typeof(StatisticsManager);
            type.GetField("_config", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(manager,
                new Config { IndexId = "node", GuiItem = new GUIItem { EnableStatistics = true } });
            type.GetField("_updateFunc", BindingFlags.NonPublic | BindingFlags.Instance)!.SetValue(manager,
                (Func<ServerSpeedItem, Task>)(_ => Task.CompletedTask));
            async Task Invoke(string method, params object[] args) =>
                await (Task)type.GetMethod(method, BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(manager, args)!;
            await Invoke("InitData");
            await Invoke("UpdateServerStat", new ServerSpeedItem { ProxyUp = 10 });
            await manager.SaveTo();
            await Invoke("InitData");
            await Invoke("UpdateServerStat", new ServerSpeedItem { ProxyUp = 20 });
            await manager.SaveTo();
            var item = (await db.TableAsync<ServerStatItem>().ToListAsync()).Single();
            await item.TotalUp.Should().BeEqualTo(30L);
        }
        finally { await db.DisposeDbConnectionAsync(); Directory.Delete(directory, true); }
    }
}
