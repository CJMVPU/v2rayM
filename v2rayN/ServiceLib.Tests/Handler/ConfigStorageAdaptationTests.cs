using ServiceLib.Tests.CoreConfig;

namespace ServiceLib.Tests.Handler;

[NotInParallel]
public class ConfigStorageAdaptationTests
{
    [Test]
    public async Task DefaultSelectionUsesTransactionConfigInsteadOfSharedConfig()
    {
        TestDatabase.Initialize();
        var previous = ConfigTextHandler.Config;
        var shared = CoreConfigTestFactory.CreateConfig();
        var snapshot = CoreConfigTestFactory.CreateConfig();
        shared.IndexId = "shared-" + Guid.NewGuid().ToString("N");
        snapshot.IndexId = "snapshot-" + Guid.NewGuid().ToString("N");
        var item = new ProfileItem { IndexId = snapshot.IndexId, Remarks = "transaction-owned selection" };
        try
        {
            ConfigState.Instance.SetCurrent(shared);
            await SQLiteHelper.Instance.InsertAsync(item);
            var selected = await ConfigTextHandler.GetDefaultServer(snapshot);
            await selected!.IndexId.Should().BeEqualTo(snapshot.IndexId);
            await ReferenceEquals(ConfigTextHandler.Config, shared).Should().BeTrue();
            await (shared.IndexId != snapshot.IndexId).Should().BeTrue();
        }
        finally
        {
            await SQLiteHelper.Instance.DeleteAsync(item);
            ConfigState.Instance.SetCurrent(previous);
        }
    }

    [Test]
    public async Task RelocatedQueriesKeepSqlParametersForSubscriptionIdsAndFilters()
    {
        TestDatabase.Initialize();
        var marker = Guid.NewGuid().ToString("N");
        var group = marker + "' OR 1=1 --";
        var expected = new ProfileItem { IndexId = marker, Subid = group, Remarks = "O'Reilly " + marker };
        var unrelated = new ProfileItem { IndexId = marker + "-other", Subid = marker, Remarks = expected.Remarks };
        try
        {
            await SQLiteHelper.Instance.InsertAsync(expected);
            await SQLiteHelper.Instance.InsertAsync(unrelated);
            var rows = await ConfigDbQuery.ProfileModels(group, "O'Reilly " + marker);
            await rows!.Count.Should().BeEqualTo(1);
            await rows[0].IndexId.Should().BeEqualTo(expected.IndexId);
        }
        finally
        {
            await SQLiteHelper.Instance.DeleteAsync(expected);
            await SQLiteHelper.Instance.DeleteAsync(unrelated);
        }
    }

    [Test]
    public async Task SharedTestSchemaInitializationDoesNotReenterDdlDuringTransaction()
    {
        TestDatabase.Initialize();
        var db = SQLiteHelper.Instance;
        var item = new SubItem { Id = Guid.NewGuid().ToString("N"), Remarks = "schema-init" };
        try
        {
            await db.InsertAsync(item);
            await db.ExecuteAsync("BEGIN EXCLUSIVE");
            try
            {
                TestDatabase.Initialize();
                await (await ConfigDbQuery.GetSubItem(item.Id))!.Id.Should().BeEqualTo(item.Id);
            }
            finally { await db.ExecuteAsync("ROLLBACK"); }
        }
        finally { await db.DeleteAsync(item); }
    }
}
