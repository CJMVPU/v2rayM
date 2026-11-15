using ServiceLib.Models.Configs;
using ServiceLib.Enums;
using V2rayM.Application.Settings;
using V2rayM.Domain.Settings;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Settings;

internal static class SettingsContractMapper
{
    public static InboundSettings Map(InboundSettingsInput value) => new(value.LocalPort, value.SecondLocalPortEnabled,
        value.UdpEnabled, value.SniffingEnabled, value.DestOverride, value.RouteOnly, value.AllowLANConn, value.NewPort4LAN, value.User, value.Pass);
    public static CoreSettings Map(CoreSettingsInput value) => new(value.LogEnabled, value.Loglevel, value.DefFingerprint, value.DefUserAgent,
        value.SendThrough, value.BindInterface, value.Mux4RayConcurrency, value.Mux4RayXudpConcurrency, value.Mux4RayXudpProxyUDP443,
        value.Hy2UpMbps, value.Hy2DownMbps, value.EnableFragment, value.EnableFinalFragment, value.FragmentPackets,
        value.FragmentLengths, value.FragmentDelays, value.FragmentMaxSplit);
    public static ApplicationSettings Map(AppSettingsInput value) => new(value.EnableStatistics, value.DisplayRealTimeSpeed, value.KeepOlderDedupl,
        value.GeoAutoUpdateInterval, value.RootCertProvider, value.GeoSourceUrl, value.RouteRulesTemplateSourceUrl, value.SubConvertUrl);
    public static SpeedTestSettings Map(SpeedTestSettingsInput value) => new(value.SpeedTestTimeout, value.SpeedTestUrl, value.SpeedPingTestUrl,
        value.MixedConcurrencyCount, value.IPAPIUrl, value.UdpTestTarget);
    public static CoreMapping[] Map(IEnumerable<CoreTypeMapping> values) => values.Select(value => new CoreMapping((int)value.ConfigType, value.CoreType == ECoreType.Xray)).ToArray();
    public static SimpleDnsSettings Map(SimpleDNSItem value) => new(
        value.UseSystemHosts, value.AddCommonHosts, value.FakeIP, value.GlobalFakeIp, value.FakeIPRange, value.BlockBindingQuery, value.BlockAAAAQuery, value.DirectDNS, value.RemoteDNS, value.BootstrapDNS, value.Strategy4Freedom, value.Strategy4Proxy, value.Strategy4ProxyDial, value.ServeStale, value.ParallelQuery, value.Hosts, value.DirectExpectedIPs, value.EnableHappyEyeballs);
    public static DnsProfileSettings Map(DnsProfileInput value) => new(value.Remarks, value.Enabled, value.UseSystemHosts,
        value.NormalDNS, value.TunDNS, value.DomainStrategy4Freedom, value.DomainDNSAddress);
    public static CoreTemplateSettings Map(CoreConfigTemplateInput value) => new(value.Remarks, value.Enabled, value.Config,
        value.TunConfig, value.AddProxyOnly, value.ProxyDetour);
    public static SettingsEdit Map(SettingsApplyInput input) => new(Map(input.Inbound), Map(input.Core), Map(input.Application), Map(input.SpeedTest),
        Map(input.CoreTypes), new(input.DomainStrategy), input.NativeTun is { } tun ? new(tun.Mtu, tun.EnableIPv6Address, tun.RouteExcludeAddress) : null);

    public static OperationView Failure(SettingsEditResult result, string section, object? data = null)
    {
        if (result.Status == SettingsEditStatus.NotFound)
            return OperationView.Fail(section == "dns-profile" ? "dns_profile_not_found" : "core_template_not_found",
                section == "dns-profile" ? ApiMessageKeys.DnsProfileNotFound : ApiMessageKeys.CommonNotFound, data);
        if (result.Status == SettingsEditStatus.PersistenceFailed && section is "dns-profile" or "core-template")
            return OperationView.Fail(section == "dns-profile" ? "dns_profile_save_failed" : "core_template_save_failed",
                section == "dns-profile" ? ApiMessageKeys.DnsSaveFailed : ApiMessageKeys.CommonInvalidInput,
                new { configRestored = result.ConfigRestored, detail = result.Detail, rollbackDetail = result.RollbackDetail });
        if (result.Status == SettingsEditStatus.PersistenceFailed)
            return OperationView.Fail("settings_transaction_failed", ApiMessageKeys.CommonInternal, new
            {
                stage = "config_save", exceptionType = result.ExceptionType, detail = result.Detail,
                configRestored = result.ConfigRestored, rollbackDetail = result.RollbackDetail,
            });
        return ValidationFailure(result.Validation, section);
    }
    public static OperationView ValidationFailure(SettingsValidationError error, string section)
    {
        var all = section == "all-settings";
        var (code, key) = error switch
        {
            SettingsValidationError.DnsProfile => ("dns_profile_invalid", ApiMessageKeys.CommonInvalidInput),
            SettingsValidationError.NativeTun => ("mac_tun_settings_invalid", ApiMessageKeys.CommonInvalidInput),
            SettingsValidationError.Credentials => ("inbound_lan_credentials_invalid", ApiMessageKeys.CommonInvalidInput),
            SettingsValidationError.Port => ("inbound_port_invalid", ApiMessageKeys.SettingsInvalidPort),
            SettingsValidationError.SniffingProtocols when all => ("inbound_port_invalid", ApiMessageKeys.SettingsInvalidPort),
            SettingsValidationError.SniffingProtocols => ("inbound_dest_override_invalid", ApiMessageKeys.CommonInvalidInput),
            SettingsValidationError.CoreOptions or SettingsValidationError.LogLevel or SettingsValidationError.CoreNumbers or SettingsValidationError.Fragment when all
                => ("core_setting_invalid", ApiMessageKeys.SettingsInvalidCoreValue),
            SettingsValidationError.CoreOptions => ("core_setting_option_invalid", ApiMessageKeys.SettingsInvalidCoreValue),
            SettingsValidationError.LogLevel => ("core_log_level_invalid", ApiMessageKeys.SettingsInvalidCoreLogLevel),
            SettingsValidationError.CoreNumbers => ("core_setting_out_of_range", ApiMessageKeys.SettingsInvalidCoreValue),
            SettingsValidationError.Fragment => ("fragment_setting_invalid", ApiMessageKeys.SettingsInvalidFragment),
            SettingsValidationError.Application or SettingsValidationError.SpeedTest when all => ("settings_apply_invalid", ApiMessageKeys.SettingsInvalidSpeedTest),
            SettingsValidationError.Application => ("app_setting_invalid", ApiMessageKeys.CommonInvalidInput),
            SettingsValidationError.SpeedTest => ("speedtest_settings_invalid", ApiMessageKeys.SettingsInvalidSpeedTest),
            SettingsValidationError.CoreTypes or SettingsValidationError.RoutingStrategy when all => ("settings_apply_invalid", ApiMessageKeys.CommonInvalidInput),
            SettingsValidationError.CoreTypes => ("core_type_mapping_invalid", ApiMessageKeys.CommonInvalidInput),
            _ => ("routing_strategy_invalid", ApiMessageKeys.SettingsInvalidRoutingStrategy),
        };
        return OperationView.Fail(code, key);
    }
}
