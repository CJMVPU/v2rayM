namespace v2rayN.WebAPI.Services;

internal static class BackupConfigSnapshot
{
    private const string DatabaseName = "guiNDB.db";
    public static async Task CaptureAsync(string source, string destination, Func<string, Task> backupDatabase)
    {
        CopyFiles(source, destination);
        if (File.Exists(Path.Combine(source, DatabaseName)))
            await backupDatabase(Path.Combine(destination, DatabaseName));
    }

    public static void CopyFiles(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var path in Directory.EnumerateFiles(source, "*", SearchOption.TopDirectoryOnly))
        {
            var name = Path.GetFileName(path);
            // The database backup API includes committed WAL content. Copying its
            // live database/journal files separately can produce a torn snapshot.
            if (name.Contains(V2rayRuntime.WebAuthFileName, StringComparison.OrdinalIgnoreCase)
                || name.Equals(DatabaseName, StringComparison.OrdinalIgnoreCase)
                || name.Equals(DatabaseName + "-wal", StringComparison.OrdinalIgnoreCase)
                || name.Equals(DatabaseName + "-shm", StringComparison.OrdinalIgnoreCase)
                || name.Equals(DatabaseName + "-journal", StringComparison.OrdinalIgnoreCase)
                || Path.GetExtension(name) == name) continue;
            File.Copy(path, Path.Combine(destination, name), overwrite: true);
        }
    }
}
