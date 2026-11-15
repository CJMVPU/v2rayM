namespace V2rayM.Domain.Profiles;

public static class ProfileSelection
{
    public static string[] Normalize(IEnumerable<string> ids) =>
        ids.Where(id => !string.IsNullOrWhiteSpace(id)).Distinct(StringComparer.Ordinal).ToArray();
}

public enum ProfileMove { Top, Up, Down, Bottom, Position }
public enum ProfileSortField
{
    Def, ConfigType, Remarks, Address, Port, Network, StreamSecurity, SubRemarks,
    DelayVal, SpeedVal, IpInfo, TodayDown, TodayUp, TotalDown, TotalUp
}
