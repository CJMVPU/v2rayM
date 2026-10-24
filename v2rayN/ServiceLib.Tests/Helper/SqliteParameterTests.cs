namespace ServiceLib.Tests.Helper;

public class SqliteParameterTests
{
    [Test]
    public async Task ConcurrentWriteCannotJoinAnotherOperationsRollbackTransaction()
    {
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-sql-transaction-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var db = new SQLiteHelper(Path.Combine(directory, "test.db"));
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        try
        {
            db.CreateTable<ProfileExItem>();
            var transaction = db.RunInTransactionAsync(connection =>
            {
                connection.Insert(new ProfileExItem { IndexId = "rolled-back" });
                entered.Set();
                if (!release.Wait(TimeSpan.FromSeconds(5))) throw new TimeoutException();
                throw new InvalidOperationException("injected rollback");
            });
            await Task.Run(() => entered.Wait(TimeSpan.FromSeconds(5)));
            var independent = db.InsertAsync(new ProfileExItem { IndexId = "independent" });
            await Task.Delay(100);
            release.Set();
            try { await transaction; } catch (InvalidOperationException) { }
            await independent;
            var rows = await db.TableAsync<ProfileExItem>().ToListAsync();
            await rows.Single().IndexId.Should().BeEqualTo("independent");
        }
        finally { release.Set(); await db.DisposeDbConnectionAsync(); Directory.Delete(directory, true); }
    }

    [Test]
    public async Task QuotedSubscriptionIdsRemainLiteralForQueriesAndDeletion()
    {
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-sql-parameters-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var db = new SQLiteHelper(Path.Combine(directory, "test.db"));
        try
        {
            db.CreateTable<ProfileItem>();
            const string unusualId = "legacy' OR 1=1 --";
            await db.InsertAsync(new ProfileItem { IndexId = "quoted", Subid = unusualId });
            await db.InsertAsync(new ProfileItem { IndexId = "ordinary", Subid = "other" });
            var matching = await db.QueryAsync<ProfileItem>("select * from ProfileItem where subid = ?", unusualId);
            await matching.Single().IndexId.Should().BeEqualTo("quoted");
            await db.ExecuteAsync("delete from ProfileItem where subid = ?", unusualId);
            await (await db.TableAsync<ProfileItem>().ToListAsync()).Single().IndexId.Should().BeEqualTo("ordinary");
        }
        finally { await db.DisposeDbConnectionAsync(); Directory.Delete(directory, true); }
    }
}
