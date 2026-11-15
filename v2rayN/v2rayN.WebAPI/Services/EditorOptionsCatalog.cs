using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

internal static class EditorOptionsCatalog
{
    private const int DefaultWireGuardMtu = 1280;
    private static readonly Lazy<ProfileEditorOptionsView> ProfileEditorOptionsValue = new(CreateProfileEditorOptions);

    public static WebSettingsOptionsView GetWebSettingsOptions() => new(
        Global.LogLevels.ToArray(),
        Global.RootCertProviders.ToArray(),
        Global.Fingerprints.ToArray(),
        Global.UserAgent.ToArray(),
        ["reject", "skip"],
        Global.FragmentPacketsOptions.ToArray(),
        Global.destOverrideProtocols.ToArray(),
        Global.DomainStrategies.ToArray(),
        Global.DomainStrategies.AppendEmpty().ToArray(),
        Enumerable.Range(Global.SpeedTestConcurrencyCountMin, 20).ToArray(),
        Enumerable.Range(2, 5).Select(value => value * 5).ToArray(),
        Global.SpeedTestUrls.ToArray(),
        Global.SpeedPingTestUrls.ToArray(),
        Global.UdpTestTargets.ToArray(),
        Global.IPAPIUrls.ToArray(),
        Global.SubConvertUrls.ToArray(),
        Global.GeoFilesSources.ToArray(),
        Global.RoutingRulesSources.ToArray());

    public static WebEditorOptionsView GetEditorOptions() => new(
        new SubscriptionEditorOptionsView(
            Global.SubConvertTargets.ToArray(),
            [nameof(ECoreType.Xray)]),
        ProfileEditorOptionsValue.Value,
        GetDnsEditorOptions());

    private static ProfileEditorOptionsView CreateProfileEditorOptions()
    {
        var shadowsocksMethods = new[] { ECoreType.Xray }
            .ToDictionary(
                coreType => coreType.ToString(),
                coreType => Global.SsSecuritiesInXray.ToArray(),
                StringComparer.OrdinalIgnoreCase);

        return new ProfileEditorOptionsView(
            Global.CoreTypes.ToArray(),
            Global.XraySupportConfigType.Select(configType => configType.ToString()).ToArray(),
            Global.Networks.ToArray(),
            Global.DefaultNetwork,
            new ProfileItem().StreamSecurity,
            Global.DefaultSecurity,
            Global.None,
            Global.DefaultXhttpMode,
            Global.GrpcGunMode,
            DefaultWireGuardMtu,
            [Global.None, Global.RawHeaderHttp],
            Global.XhttpMode.ToArray(),
            [Global.None, .. Global.KcpHeaderTypes],
            [Global.GrpcGunMode, Global.GrpcMultiMode],
            Global.VmessSecurities.ToArray(),
            Global.Flows.ToArray(),
            Global.TuicCongestionControls.ToArray(),
            Global.NaiveCongestionControls.ToArray(),
            Global.Fingerprints.ToArray(),
            Global.Alpns.ToArray(),
            shadowsocksMethods,
            [string.Empty, Global.StreamSecurity, Global.StreamSecurityReality],
            Enum.GetNames<EMultipleLoad>());
    }

    public static DnsEditorOptionsView GetDnsEditorOptions() => new(
        Global.CoreTypes.ToArray(),
        Global.DomainStrategy.ToArray(),
        Global.DomainPureIPDNSAddress.ToArray(),
        Global.DomainDirectDNSAddress.ToArray(),
        Global.DomainRemoteDNSAddress.ToArray(),
        Global.DomainPureIPDNSAddress.ToArray(),
        Global.FakeIPRanges.ToArray(),
        Global.ExpectedIPs.ToArray());

}
