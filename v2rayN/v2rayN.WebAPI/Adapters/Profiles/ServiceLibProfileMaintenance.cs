using ServiceLib.Handler;
using ServiceLib.Handler.Builder;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using V2rayM.Application.Profiles;
using V2rayM.Domain.Profiles;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal sealed class ServiceLibProfileMaintenance(Func<Config> config, Func<string?> running) : IProfileMaintenanceStore
{
    public string SelectedGroup => config().SubIndexId ?? string.Empty;
    private bool Eligible(ProfileItem item) => ProfileCleanupPolicy.CanRemove(XrayOnlyPolicy.Supports(item), item.IsComplex(),
        item.IndexId == config().IndexId || item.IndexId == running());
    public async Task<int> DeduplicateAsync(string group)
    {
        var result = await ConfigDbHandler.DedupServerList(config(), group, Eligible);
        return result.Item1 - result.Item2;
    }
    public Task<int> RemoveFailedAsync(string group) => ConfigDbHandler.RemoveInvalidServerResult(config(), group, Eligible);
    public async Task<bool> GroupExistsAsync(string group) => await ConfigDbQuery.GetSubItem(group) is not null;
    public async Task<ProfileGroupGeneration> GenerateAsync(string? group, bool byRegion)
    {
        var subscription = string.IsNullOrEmpty(group) ? null : await ConfigDbQuery.GetSubItem(group);
        var result = byRegion ? await ConfigDbHandler.AddGroupRegionServer(config(), subscription) : await ConfigDbHandler.AddGroupAllServer(config(), subscription);
        return new(result.Success, result.Data as string, result.Data as IReadOnlyList<string>);
    }
}
