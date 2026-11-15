using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Adapters.Settings;

internal sealed class ServiceLibUpdatePreferences(IRuntimeConfigStore store) : IUpdatePreferenceStore
{
    public async Task<IUpdatePreferenceSession> CaptureAsync()
    {
        await store.RecoverPendingRestoreAsync();
        return new Session(store, await store.CaptureAsync());
    }

    private sealed class Session(IRuntimeConfigStore store, RuntimeConfigSnapshot snapshot) : IUpdatePreferenceSession
    {
        public UpdatePreferences Current => new(V2rayRuntime.NormalizeWebUpdateTargets(store.Current.CheckUpdateItem.SelectedCoreTypes),
            V2rayRuntime.NormalizeWebUpdateTargets(store.Current.CheckUpdateItem.CheckPreReleaseCoreTypes), store.Current.CheckUpdateItem.UpdateViaProxy);
        public async Task SaveAsync(UpdatePreferences preferences)
        {
            var item = store.Current.CheckUpdateItem;
            item.SelectedCoreTypes = preferences.SelectedTargets?.ToList();
            item.CheckPreReleaseCoreTypes = preferences.PreReleaseTargets?.ToList();
            item.UpdateViaProxy = preferences.UseProxy;
            if (await store.SaveAsync() != 0) throw new IOException("ServiceLib could not persist update preferences.");
        }
        public Task RestoreAsync() => store.RestoreAsync(snapshot);
    }
}
