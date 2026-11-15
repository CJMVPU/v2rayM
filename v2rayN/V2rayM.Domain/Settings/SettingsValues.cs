namespace V2rayM.Domain.Settings;

public sealed record InboundSettings(
    int LocalPort,
    bool SecondLocalPortEnabled,
    bool UdpEnabled,
    bool SniffingEnabled,
    string[]? DestOverride,
    bool RouteOnly,
    bool AllowLANConn,
    bool NewPort4LAN,
    string? User,
    string? Pass);

public sealed record CoreSettings(
    bool LogEnabled,
    string? Loglevel,
    string? DefFingerprint,
    string? DefUserAgent,
    string? SendThrough,
    string? BindInterface,
    int? Mux4RayConcurrency,
    int? Mux4RayXudpConcurrency,
    string? Mux4RayXudpProxyUDP443,
    int Hy2UpMbps,
    int Hy2DownMbps,
    bool EnableFragment,
    bool EnableFinalFragment,
    string? FragmentPackets,
    string[]? FragmentLengths,
    string[]? FragmentDelays,
    string? FragmentMaxSplit);

public sealed record ApplicationSettings(
    bool EnableStatistics,
    bool DisplayRealTimeSpeed,
    bool KeepOlderDedupl,
    int GeoAutoUpdateInterval,
    string? RootCertProvider,
    string? GeoSourceUrl,
    string? RouteRulesTemplateSourceUrl,
    string? SubConvertUrl);

public sealed record SpeedTestSettings(
    int SpeedTestTimeout,
    string SpeedTestUrl,
    string SpeedPingTestUrl,
    int MixedConcurrencyCount,
    string IPAPIUrl,
    string UdpTestTarget);

public sealed record CoreMapping(int Protocol, bool UsesXray);
public sealed record RoutingStrategy(string? Value);
public sealed record NativeTunSettings(int Mtu, bool EnableIPv6Address, string[]? RouteExcludeAddress);
public sealed record StatisticsSelection(bool Enabled, bool RealTime);

public static class SettingsPolicy
{
    public static bool ValidCredentials(InboundSettings input) => !input.AllowLANConn || !input.NewPort4LAN
        || string.IsNullOrWhiteSpace(input.User) == string.IsNullOrWhiteSpace(input.Pass);
    public static bool ValidPort(InboundSettings input)
    {
        var offset = input.SecondLocalPortEnabled || (input.AllowLANConn && input.NewPort4LAN) ? 2 : 0;
        return input.LocalPort > 0 && input.LocalPort <= 65535 - offset;
    }
    public static bool ValidCoreNumbers(CoreSettings input) =>
        input.Mux4RayConcurrency is null or >= 0 and <= 1024
        && input.Mux4RayXudpConcurrency is null or >= 0 and <= 1024
        && input.Hy2UpMbps >= 0 && input.Hy2DownMbps >= 0;
    public static bool ValidSpeedTest(SpeedTestSettings input) =>
        input.SpeedTestTimeout > 0 && input.MixedConcurrencyCount > 0
        && IsHttpUrl(input.SpeedTestUrl) && IsHttpUrl(input.SpeedPingTestUrl);
    private static bool IsHttpUrl(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https";
    public static string[] SniffingProtocols(bool enabled, IEnumerable<string>? requested, IEnumerable<string> defaults)
    {
        var protocols = requested?.ToArray() ?? [];
        return enabled && protocols.Length == 0 ? defaults.ToArray() : protocols;
    }
}
