using ServiceLib.Common;
using ServiceLib.Handler;
using ServiceLib.Helper;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;

namespace v2rayN.WebAPI.Services;

public sealed record RuntimeConfigSnapshot(Config Config, RoutingItem[] Routing, DNSItem[] Dns, FullConfigTemplateItem[] Templates);

/// The adapter contains legacy singleton access. Runtime transactions can be
/// tested with isolated stores without replacing process-global private fields.
public interface IRuntimeConfigStore
{
    Config Current { get; }
    Task<int> SaveAsync();
    Task<RuntimeConfigSnapshot> CaptureAsync();
    Task RestoreAsync(RuntimeConfigSnapshot snapshot);
    Task RecoverPendingRestoreAsync() => Task.CompletedTask;
}

internal sealed class ServiceLibRuntimeConfigStore : IRuntimeConfigStore
{
    public Config Current => AppManager.Instance.Config;
    public Task<int> SaveAsync() => ConfigHandler.SaveConfig(Current);
    public async Task<RuntimeConfigSnapshot> CaptureAsync() => new(
        JsonUtils.DeepCopy(Current) ?? throw new InvalidOperationException("Could not snapshot runtime configuration."),
        (await AppManager.Instance.RoutingItems() ?? []).ToArray(),
        (await AppManager.Instance.DNSItems() ?? []).ToArray(),
        (await AppManager.Instance.FullConfigTemplateItem() ?? []).ToArray());

    private readonly JournaledConfigRestorer _restorer;
    public ServiceLibRuntimeConfigStore()
    {
        _restorer = new JournaledConfigRestorer(() => Utils.GetConfigPath("native-settings-restore.json"), ApplySnapshotAsync);
    }
    public Task RecoverPendingRestoreAsync() => _restorer.RecoverAsync();
    public Task RestoreAsync(RuntimeConfigSnapshot snapshot) => _restorer.RestoreAsync(snapshot);

    private async Task ApplySnapshotAsync(RuntimeConfigSnapshot snapshot)
    {
        await RestoreTablesAsync(snapshot);
        CopyValues(Current, snapshot.Config);
        if (await SaveAsync() != 0) throw new IOException("Could not restore configuration; recovery journal retained for retry.");
        AppManager.Instance.Reset();
    }

    private static Task RestoreTablesAsync(RuntimeConfigSnapshot snapshot) => SQLiteHelper.Instance.RunInTransactionAsync(db =>
        RestoreTables(db, snapshot));

    internal static void RestoreTables(SQLite.SQLiteConnection db, RuntimeConfigSnapshot snapshot)
    {
        db.DeleteAll<RoutingItem>();
        if (db.InsertAll(snapshot.Routing, runInTransaction: false) != snapshot.Routing.Length)
            throw new IOException("Routing snapshot could not be restored.");
        db.DeleteAll<DNSItem>();
        if (db.InsertAll(snapshot.Dns, runInTransaction: false) != snapshot.Dns.Length)
            throw new IOException("DNS snapshot could not be restored.");
        db.DeleteAll<FullConfigTemplateItem>();
        if (db.InsertAll(snapshot.Templates, runInTransaction: false) != snapshot.Templates.Length)
            throw new IOException("Template snapshot could not be restored.");
    }

    internal static void CopyValues(Config target, Config snapshot)
    {
        foreach (var property in typeof(Config).GetProperties(System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public))
            if (property.CanRead && property.CanWrite) property.SetValue(target, property.GetValue(snapshot));
    }
}
