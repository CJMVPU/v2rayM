namespace V2rayM.Domain.Settings;

public sealed record SimpleDnsSettings(
    bool? UseSystemHosts,
    bool? AddCommonHosts,
    bool? FakeIP,
    bool? GlobalFakeIp,
    string? FakeIPRange,
    bool? BlockBindingQuery,
    bool? BlockAAAAQuery,
    string? DirectDNS,
    string? RemoteDNS,
    string? BootstrapDNS,
    string? Strategy4Freedom,
    string? Strategy4Proxy,
    string? Strategy4ProxyDial,
    bool? ServeStale,
    bool? ParallelQuery,
    string? Hosts,
    string? DirectExpectedIPs,
    bool? EnableHappyEyeballs);

public sealed record DnsProfileSettings(string? Remarks, bool Enabled, bool UseSystemHosts, string? NormalDNS,
    string? TunDNS, string? DomainStrategy4Freedom, string? DomainDNSAddress)
{
    public DnsRuntimeConfiguration? ForRuntime(bool tun) => Enabled
        ? new(UseSystemHosts, (tun ? TunDNS : NormalDNS) ?? "", DomainStrategy4Freedom ?? "", DomainDNSAddress ?? "") : null;
}
public sealed record DnsRuntimeConfiguration(bool UseSystemHosts, string Content, string DomainStrategy4Freedom, string DomainDNSAddress);

public sealed record CoreTemplateSettings(string? Remarks, bool Enabled, string? Config, string? TunConfig,
    bool? AddProxyOnly, string? ProxyDetour)
{
    public TemplateRuntimeConfiguration? ForRuntime(bool tun)
    {
        var content = tun ? TunConfig : Config;
        // The generator bypasses disabled templates and empty mode-specific content.
        return !Enabled || string.IsNullOrEmpty(content) ? null : new(content, AddProxyOnly == true, ProxyDetour ?? "");
    }
}
public sealed record TemplateRuntimeConfiguration(string Content, bool AddProxyOnly, string ProxyDetour);
