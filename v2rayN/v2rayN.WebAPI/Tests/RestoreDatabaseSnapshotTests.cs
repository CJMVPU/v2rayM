using SQLite;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class RestoreDatabaseSnapshotTests
{
    [Test]
    public async Task FailedSwapKeepsDisplacedDirectoryEvenWhenCandidateCleanupFails()
    {
        var root = Path.Combine(Path.GetTempPath(), "restore-displaced-" + Guid.NewGuid().ToString("N"));
        var current = Path.Combine(root, "current"); var displaced = Path.Combine(root, "displaced");
        Directory.CreateDirectory(current);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(current, "config.json"), "only old copy");
            try
            {
                RestoreDirectoryTransaction.Apply(() => { },
                    () => { Directory.Move(current, displaced); throw new IOException("swap and rollback failed"); },
                    () => throw new IOException("candidate cleanup failed"), () => Directory.Delete(displaced, true));
            }
            catch (IOException) { }
            await (await File.ReadAllTextAsync(Path.Combine(displaced, "config.json"))).Should().BeEqualTo("only old copy");
        }
        finally { Directory.Delete(root, true); }
    }

    [Test]
    public async Task LegacyWalArchiveBecomesStandaloneAndCannotReuseDisplacedDatabaseJournal()
    {
        var root = Path.Combine(Path.GetTempPath(), "restore-database-" + Guid.NewGuid().ToString("N"));
        var source = Path.Combine(root, "legacy"); var stage = Path.Combine(root, "stage");
        var current = Path.Combine(root, "current"); var candidate = Path.Combine(root, "candidate");
        Directory.CreateDirectory(source); Directory.CreateDirectory(stage); Directory.CreateDirectory(current);
        try
        {
            using (var database = new SQLiteConnection(Path.Combine(source, "guiNDB.db")))
            {
                database.ExecuteScalar<string>("PRAGMA journal_mode=WAL");
                database.Execute("CREATE TABLE ProfileItem (IndexId TEXT PRIMARY KEY, Remarks TEXT)");
                database.Execute("INSERT INTO ProfileItem VALUES ('from-wal','new')");
                // Model an old archive containing a database and its own committed WAL.
                foreach (var file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(stage, Path.GetFileName(file)));
            }
            await File.Exists(Path.Combine(stage, "guiNDB.db-wal")).Should().BeTrue();
            RestoreDatabaseSnapshot.Normalize(stage);
            await File.Exists(Path.Combine(stage, "guiNDB.db-wal")).Should().BeFalse();
            await File.WriteAllTextAsync(Path.Combine(current, "guiNDB.db-wal"), "unrelated old journal");
            await File.WriteAllTextAsync(Path.Combine(current, "guiNDB.db-shm"), "unrelated old shared memory");
            await File.WriteAllTextAsync(Path.Combine(current, "WebAPI-auth.json"), "local verifier");
            await File.WriteAllTextAsync(Path.Combine(stage, "guiNConfig.json"), "{}");
            V2rayRuntime.PrepareRestoredConfigDirectory(stage, current, candidate);
            await File.Exists(Path.Combine(candidate, "guiNDB.db-wal")).Should().BeFalse();
            await File.Exists(Path.Combine(candidate, "guiNDB.db-shm")).Should().BeFalse();
            await (await File.ReadAllTextAsync(Path.Combine(candidate, "WebAPI-auth.json"))).Should().BeEqualTo("local verifier");
            using var restored = new SQLiteConnection(Path.Combine(candidate, "guiNDB.db"));
            await restored.ExecuteScalar<string>("SELECT Remarks FROM ProfileItem WHERE IndexId='from-wal'").Should().BeEqualTo("new");
            await restored.ExecuteScalar<string>("PRAGMA integrity_check").Should().BeEqualTo("ok");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    [Test]
    public async Task OrphanJournalIsRejectedInsteadOfBeingAppliedToCurrentDatabase()
    {
        var root = Path.Combine(Path.GetTempPath(), "restore-orphan-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            await File.WriteAllTextAsync(Path.Combine(root, "guiNDB.db-wal"), "orphan");
            var rejected = false;
            try { RestoreDatabaseSnapshot.Normalize(root); } catch (InvalidDataException) { rejected = true; }
            await rejected.Should().BeTrue();
        }
        finally { Directory.Delete(root, true); }
    }
}
