using ServiceLib.Common;

namespace v2rayN.WebAPI.Services;

/// SQLite table replacement is atomic; SQLite plus JSON are not one atomic
/// resource. Persist the desired rollback first and replay it on startup/retry.
/// A failed replay never deletes/overwrites the pending intent.
internal sealed class JournaledConfigRestorer(Func<string> journalPath, Func<RuntimeConfigSnapshot, Task> apply)
{
    public async Task RestoreAsync(RuntimeConfigSnapshot snapshot)
    {
        await RecoverAsync();
        var path = journalPath();
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None,
                Options = FileOptions.Asynchronous | FileOptions.WriteThrough };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            await using (var stream = new FileStream(temporary, options))
            {
                var bytes = System.Text.Encoding.UTF8.GetBytes(JsonUtils.Serialize(snapshot));
                await stream.WriteAsync(bytes);
                await stream.FlushAsync();
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        await RecoverAsync();
    }

    public async Task RecoverAsync()
    {
        var path = journalPath();
        if (!File.Exists(path)) return;
        var snapshot = JsonUtils.Deserialize<RuntimeConfigSnapshot>(await File.ReadAllTextAsync(path))
            ?? throw new InvalidDataException("Configuration recovery journal is invalid; retained for diagnosis.");
        if (snapshot.Config is null || snapshot.Routing is null || snapshot.Dns is null || snapshot.Templates is null)
            throw new InvalidDataException("Configuration recovery journal is incomplete; retained for diagnosis.");
        await apply(snapshot);
        File.Delete(path);
    }
}
