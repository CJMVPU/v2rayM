using ServiceLib.Handler.Builder;
using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using V2rayM.Application.Profiles;
using V2rayM.Domain.Profiles;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal sealed class ServiceLibProfileEditor(Func<Config> config, Func<string, bool> running) : IProfileEditorRepository
{
    public string SelectedGroup => config().SubIndexId ?? string.Empty;
    public async Task<ProfileIdentity?> FindAsync(string id) => await AppManager.Instance.GetProfileItem(id) is { } item
        ? new(item.IndexId, (int)item.ConfigType, item.Subid, item.IsSub) : null;
    public async Task<bool> GroupExistsAsync(string id) => await AppManager.Instance.GetSubItem(id) is not null;
    public async Task<int> CountChildrenAsync(IReadOnlyList<string> ids) => (await AppManager.Instance.GetProfileItemsByIndexIds(ids.ToArray())).Count;
    public bool IsRunning(string id) => running(id);
}

internal sealed class ServiceLibProfileEditSession(ProfileItem profile, Func<Config> config) : IProfileEditSession
{
    public string Id => profile.IndexId;
    public ProfileEditFacts Facts => Describe(profile);
    internal static ProfileEditFacts Describe(ProfileItem profile)
    {
        var extra = profile.GetProtocolExtra();
        var kind = profile.ConfigType.IsGroupType() ? ProfileKind.Group : profile.ConfigType switch
        {
            EConfigType.Custom => ProfileKind.Custom, EConfigType.Outbound => ProfileKind.Outbound,
            _ => profile.ConfigType.IsComplexType() ? ProfileKind.ImportOnly : ProfileKind.Simple,
        };
        return new((int)profile.ConfigType, kind, XrayOnlyPolicy.Supports(profile), profile.Remarks,
            profile.Address, profile.Port, profile.Password, profile.ConfigType is not EConfigType.SOCKS and not EConfigType.HTTP,
            profile.ConfigType == EConfigType.Shadowsocks, extra.SsMethod,
            profile.ConfigType != EConfigType.HTTP || string.IsNullOrEmpty(extra.HttpHeaders) || JsonUtils.ParseJson(extra.HttpHeaders) is not null,
            profile.CoreType is null or ECoreType.Xray, Utils.String2List(extra.ChildItems) ?? [], extra.SubChildItems);
    }
    public void Bind(ProfileIdentity identity)
    {
        profile.IndexId = identity.Id; profile.Subid = identity.GroupId; profile.IsSub = identity.FromSubscription;
        if (profile.ConfigType.IsGroupType()) profile.CoreType ??= ECoreType.Xray;
    }
    public Task<bool> HasCycleAsync() => GroupProfileManager.HasCycle(profile);
    public Task<int> PersistAsync(bool isNew) => profile.ConfigType.IsGroupType()
        ? ConfigHandler.AddServerCommon(config(), profile)
        : profile.ConfigType switch
        {
            EConfigType.Custom when isNew => ConfigHandler.AddCustomServer(config(), profile, blDelete: false),
            EConfigType.Outbound when isNew => ConfigHandler.AddCustomOutboundServer(config(), profile, blDelete: false, toFile: true),
            EConfigType.Custom or EConfigType.Outbound => ConfigHandler.EditCustomServer(config(), profile),
            _ => ConfigHandler.AddServer(config(), profile),
        };
}
