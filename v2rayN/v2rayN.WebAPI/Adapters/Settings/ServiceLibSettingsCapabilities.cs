using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Enums;
using V2rayM.Application.Settings;
using V2rayM.Domain.Settings;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Adapters.Settings;

internal sealed class ServiceLibSettingsCapabilities : ISettingsCapabilities
{
    internal static readonly EConfigType[] EditableCoreTypes =
    [
        EConfigType.VMess, EConfigType.Custom, EConfigType.Shadowsocks, EConfigType.SOCKS,
        EConfigType.VLESS, EConfigType.Trojan, EConfigType.Hysteria2, EConfigType.WireGuard,
    ];
    public bool ValidNativeTun(NativeTunSettings input) => OperatingSystem.IsMacOS()
        && V2rayRuntime.ValidMacNativeTunSettings(new(input.Mtu, input.EnableIPv6Address, input.RouteExcludeAddress));
    public bool ValidSniffingProtocols(IEnumerable<string>? values) =>
        values is null || values.All(value => value == "fakedns" || Global.destOverrideProtocols.Contains(value));
    public bool ValidCoreOptions(CoreSettings input) =>
        Global.Fingerprints.Contains(input.DefFingerprint ?? string.Empty)
        && (string.IsNullOrEmpty(input.DefUserAgent) || Global.UserAgent.Contains(input.DefUserAgent))
        && (string.IsNullOrEmpty(input.Mux4RayXudpProxyUDP443) || input.Mux4RayXudpProxyUDP443 is "reject" or "skip")
        && (string.IsNullOrEmpty(input.FragmentPackets) || Global.FragmentPacketsOptions.Contains(input.FragmentPackets));
    public bool ValidLogLevel(string? value) => Global.LogLevels.Contains(value ?? string.Empty, StringComparer.OrdinalIgnoreCase);
    public bool ValidFragment(CoreSettings input) =>
        (input.FragmentLengths ?? []).All(value => Utils.TryParseRange(value, 0, int.MaxValue, out _, out _))
        && (input.FragmentDelays ?? []).All(value => Utils.TryParseRange(value, 0, int.MaxValue, out _, out _))
        && (string.IsNullOrWhiteSpace(input.FragmentMaxSplit) || Utils.TryParseMaxSplit(input.FragmentMaxSplit, 0, 10000, out _, out _));
    public bool ValidCertificateProvider(string? value) => string.IsNullOrEmpty(value) || Global.RootCertProviders.Contains(value);
    public bool ValidCoreMappings(IReadOnlyList<CoreMapping> values) =>
        values.All(value => value.UsesXray && EditableCoreTypes.Any(type => (int)type == value.Protocol))
        && values.Select(value => value.Protocol).Distinct().Count() == values.Count;
    public bool ValidRoutingStrategy(string? value) => Global.DomainStrategies.Contains(value ?? string.Empty);
    public bool ValidDnsProfile(DnsProfileSettings input) =>
        ValidCustomDns(input.NormalDNS) && ValidCustomDns(input.TunDNS)
        && Global.DomainStrategy.Contains(input.DomainStrategy4Freedom ?? string.Empty);
    internal static bool ValidCustomDns(string? content)
    {
        if (string.IsNullOrEmpty(content)) return true;
        if (!content.TrimStart().StartsWith('{')) return !content.Contains('{') && !content.Contains('}');
        var json = JsonUtils.ParseJson(content);
        return json is not null && json["servers"] is not null;
    }
}
