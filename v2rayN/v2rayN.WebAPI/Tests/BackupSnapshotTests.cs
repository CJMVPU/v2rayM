using SQLite;
using ServiceLib.Helper;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class BackupSnapshotTests
{
    [Test]
    [Arguments(true)]
    [Arguments(false)]
    public async Task OnlineSnapshotIncludesCommittedPagesAndExcludesLiveSidecarsAndAuthentication(bool wal)
    {
        var root = Path.Combine(Path.GetTempPath(), "backup-snapshot-" + Guid.NewGuid().ToString("N"));
        var source = Path.Combine(root, "source");
        var target = Path.Combine(root, "snapshot");
        Directory.CreateDirectory(source);
        var dbPath = Path.Combine(source, "guiNDB.db");
        var database = new SQLiteHelper(dbPath);
        try
        {
            await database.ExecuteAsync("CREATE TABLE SnapshotTest (Id INTEGER PRIMARY KEY, Value TEXT)");
            if (wal)
            {
                using var configuration = new SQLiteConnection(dbPath);
                configuration.ExecuteScalar<string>("PRAGMA journal_mode=WAL");
            }
            await database.ExecuteAsync("INSERT INTO SnapshotTest VALUES (1, 'committed')");
            await File.WriteAllTextAsync(Path.Combine(source, "guiNConfig.json"), "{\"IndexId\":\"one\"}");
            await File.WriteAllTextAsync(Path.Combine(source, "WEBAPI-AUTH.JSON"), "local credential");
            await File.WriteAllTextAsync(Path.Combine(source, "WebAPI-auth.json.backup"), "old credential");
            await File.WriteAllTextAsync(Path.Combine(source, "guiNDB.db-notes"), "preserve unrelated file");
            if (wal) await File.Exists(dbPath + "-wal").Should().BeTrue();
            await BackupConfigSnapshot.CaptureAsync(source, target, database.BackupAsync);
            await database.ExecuteAsync("UPDATE SnapshotTest SET Value = 'later'");
            await File.Exists(Path.Combine(target, "guiNDB.db-wal")).Should().BeFalse();
            await File.Exists(Path.Combine(target, "guiNDB.db-shm")).Should().BeFalse();
            using var snapshot = new SQLiteConnection(Path.Combine(target, "guiNDB.db"));
            await snapshot.ExecuteScalar<string>("SELECT Value FROM SnapshotTest WHERE Id = 1").Should().BeEqualTo("committed");
            await snapshot.ExecuteScalar<string>("PRAGMA integrity_check").Should().BeEqualTo("ok");
            await File.Exists(Path.Combine(target, "guiNConfig.json")).Should().BeTrue();
            await File.Exists(Path.Combine(target, "guiNDB.db-notes")).Should().BeTrue();
            await Directory.GetFiles(target).Any(path => Path.GetFileName(path).Contains("auth", StringComparison.OrdinalIgnoreCase)).Should().BeFalse();
        }
        finally { await database.DisposeDbConnectionAsync(); Directory.Delete(root, recursive: true); }
    }
}
