using SQLite;

namespace v2rayN.WebAPI.Services;

internal static class RestoreDatabaseSnapshot
{
    internal const string DatabaseName = "guiNDB.db";
    private static readonly string[] Sidecars = ["-wal", "-shm", "-journal"];

    // Older archives may contain WAL data. Fold their own committed pages into a
    // standalone database before overlaying it on the current configuration.
    public static void Normalize(string directory)
    {
        var path = Path.Combine(directory, DatabaseName);
        if (!File.Exists(path))
        {
            if (Sidecars.Any(suffix => File.Exists(path + suffix)))
                throw new InvalidDataException("Backup database sidecars have no owning database.");
            return;
        }
        var snapshot = path + ".restore-snapshot-" + Guid.NewGuid().ToString("N");
        try
        {
            using (var database = new SQLiteConnection(path, SQLiteOpenFlags.ReadOnly))
                database.Backup(snapshot);
            File.Move(snapshot, path, overwrite: true);
            DeleteSidecars(directory);
        }
        finally { if (File.Exists(snapshot)) File.Delete(snapshot); }
    }

    public static bool IsSidecar(string name) => Sidecars.Any(suffix =>
        name.Equals(DatabaseName + suffix, StringComparison.OrdinalIgnoreCase));

    public static void DeleteSidecars(string directory)
    {
        foreach (var suffix in Sidecars)
        {
            var path = Path.Combine(directory, DatabaseName + suffix);
            if (File.Exists(path)) File.Delete(path);
        }
    }
}
