namespace ServiceLib.Tests.Helper;

public class SqliteParameterTests
{
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
