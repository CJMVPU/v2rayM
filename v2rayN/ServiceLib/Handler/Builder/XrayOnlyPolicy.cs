namespace ServiceLib.Handler.Builder;

/// Product boundary shared by import, persistence, configuration and launch.
public static class XrayOnlyPolicy
{
    public static bool Supports(ProfileItem profile) =>
        (profile.CoreType is null or ECoreType.Xray)
        && (Global.XraySupportConfigType.Contains(profile.ConfigType)
            || profile.ConfigType is EConfigType.Custom or EConfigType.Outbound
            || profile.ConfigType.IsGroupType());
}
