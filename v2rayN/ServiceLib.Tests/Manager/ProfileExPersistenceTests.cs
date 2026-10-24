namespace ServiceLib.Tests.Manager;

public class ProfileExPersistenceTests
{
    [Test]
    public async Task FirstUpdatePersistsExactlyOnceAndCanBeReadByANewManager()
    {
        await WithDatabase(async db =>
        {
            var manager = new ProfileExManager(db);
            await manager.Init();
            manager.SetSort("new", 10);
            manager.SetTestDelay("new", 42);
            await manager.SaveTo();
            var restored = new ProfileExManager(db);
            await restored.Init();
            var item = (await restored.GetProfileExs()).Single();
            await item.Sort.Should().BeEqualTo(10);
            await item.Delay.Should().BeEqualTo(42);
        });
    }

    [Test]
    public async Task FailedSaveRetainsChangesForRetry()
    {
        await WithDatabase(async db =>
        {
            var manager = new ProfileExManager(db);
            await manager.Init();
            manager.SetTestDelay("new", 73);
            await db.ExecuteAsync("CREATE TRIGGER reject_save BEFORE INSERT ON ProfileExItem BEGIN SELECT RAISE(ABORT, 'injected'); END");
            try { await manager.SaveTo(); } catch (SQLiteException) { }
            await db.ExecuteAsync("DROP TRIGGER reject_save");
            await manager.SaveTo();
            await (await db.TableAsync<ProfileExItem>().ToListAsync()).Single().Delay.Should().BeEqualTo(73);
        });
    }

    [Test]
    public async Task ConcurrentUpdatesAndSavesRemainUniqueAndPersistFinalValues()
    {
        await WithDatabase(async db =>
        {
            var manager = new ProfileExManager(db);
            await manager.Init();
            await Task.WhenAll(Enumerable.Range(0, 8).Select(async worker =>
            {
                for (var i = 0; i < 100; i++)
                {
                    manager.SetTestDelay("new", i);
                    manager.SetTestSpeed("new", worker);
                    if (i % 10 == 0) await manager.SaveTo();
                }
            }));
            manager.SetTestDelay("new", 123);
            manager.SetTestSpeed("new", 456);
            await manager.SaveTo();
            await (await manager.GetProfileExs()).Count.Should().BeEqualTo(1);
            var item = (await db.TableAsync<ProfileExItem>().ToListAsync()).Single();
            await item.Delay.Should().BeEqualTo(123);
            await item.Speed.Should().BeEqualTo(456m);
        });
    }

    private static async Task WithDatabase(Func<SQLiteHelper, Task> test)
    {
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-profile-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var db = new SQLiteHelper(Path.Combine(directory, "test.db"));
        try
        {
            db.CreateTable<ProfileItem>();
            db.CreateTable<ProfileExItem>();
            await db.InsertAsync(new ProfileItem { IndexId = "new" });
            await test(db);
        }
        finally
        {
            await db.DisposeDbConnectionAsync();
            Directory.Delete(directory, true);
        }
    }
}
