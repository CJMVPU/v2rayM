using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using V2rayM.Application.Profiles;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal sealed class ServiceLibProfileRemoval(Func<Config> config, Func<(string? Id, bool Running, bool Active)> runtime,
    Func<Task> save) : IProfileRemovalRepository
{
    public string SelectedGroup => config().SubIndexId ?? string.Empty;
    public async Task<ProfileRemovalPlan> PlanAsync(IReadOnlyList<string> ids)
    {
        var items = await ConfigDbQuery.GetProfileItemsByIndexIds(ids.ToArray());
        var state = runtime();
        return new(items.Select(item => item.IndexId).ToArray(), config().IndexId, state.Id, state.Running, state.Active);
    }
    public async Task<string?> DeleteAsync(IReadOnlyList<string> ids, bool resetSelection)
    {
        var items = await ConfigDbQuery.GetProfileItemsByIndexIds(ids.ToArray());
        if (await ConfigDbHandler.RemoveServers(config(), items) != 0)
            throw new IOException("ServiceLib could not remove the selected profiles.");
        if (resetSelection)
        {
            _ = await ConfigTextHandler.GetDefaultServer(config());
            await save();
        }
        return config().IndexId;
    }
}
