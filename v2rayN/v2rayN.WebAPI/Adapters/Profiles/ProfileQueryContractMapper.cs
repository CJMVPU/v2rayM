using V2rayM.Application.Profiles;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal static class ProfileQueryContractMapper
{
    public static ProfileView ToView(ProfileListEntry item) => new(item.IndexId, item.Remarks, item.Protocol,
        item.Address, item.Port, item.Network, item.StreamSecurity, item.SubscriptionId, item.SubscriptionName,
        item.CoreType, item.Sort, item.Delay, item.Speed, item.IpInfo, item.TodayUp, item.TodayDown, item.TotalUp,
        item.TotalDown, item.IsCurrent, item.CanTest);
}
