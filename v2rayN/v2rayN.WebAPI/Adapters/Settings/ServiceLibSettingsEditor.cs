using ServiceLib.Models.Entities;
using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Models.Configs;
using V2rayM.Application.Settings;
using V2rayM.Domain.Settings;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Adapters.Settings;

internal sealed class ServiceLibSettingsEditor(IRuntimeConfigStore store, ISettingsProfileWriter? profileWriter = null) : ISettingsEditorStore
{
    public async Task<ISettingsEditSession> CaptureAsync()
    {
        await store.RecoverPendingRestoreAsync();
        return new Session(store, await store.CaptureAsync(), profileWriter ?? new ServiceLibConfigurationProfiles(() => store.Current));
    }
    private sealed class Session(IRuntimeConfigStore store, RuntimeConfigSnapshot snapshot, ISettingsProfileWriter profiles) : ISettingsEditSession
    {
        private readonly DNSItem? _dns = JsonUtils.DeepCopy(snapshot.Dns.FirstOrDefault(item => item.CoreType == ECoreType.Xray));
        private readonly FullConfigTemplateItem? _template = JsonUtils.DeepCopy(snapshot.Templates.FirstOrDefault(item => item.CoreType == ECoreType.Xray));
        private SettingsEdit? _edit;
        public string CoreFingerprint => System.Text.Json.JsonSerializer.Serialize(new
        {
            Config = Fingerprint(store.Current),
            Dns = _dns is null ? null : ServiceLibConfigurationProfiles.Describe(_dns).ForRuntime(store.Current.TunModeItem.EnableTun),
            Template = _template is null ? null : ServiceLibConfigurationProfiles.Describe(_template).ForRuntime(store.Current.TunModeItem.EnableTun),
        });
        public StatisticsSelection Statistics => new(store.Current.GuiItem.EnableStatistics, store.Current.GuiItem.DisplayRealTimeSpeed);
        public bool TryApply(SettingsEdit edit)
        {
            if (edit.DnsProfile is not null && _dns is null || edit.CoreTemplate is not null && _template is null) return false;
            ApplyValues(store.Current, edit);
            if (edit.DnsProfile is { } dns) ServiceLibConfigurationProfiles.Apply(_dns!, dns);
            if (edit.CoreTemplate is { } template) ServiceLibConfigurationProfiles.Apply(_template!, template);
            _edit = edit;
            return true;
        }
        public async Task SaveAsync()
        {
            var edit = _edit ?? throw new InvalidOperationException("Settings must be applied before persistence.");
            if (edit.DnsProfile is not null && !await profiles.SaveDnsAsync(_dns!)) throw new IOException("Could not persist DNS profile.");
            if (edit.CoreTemplate is not null && !await profiles.SaveTemplateAsync(_template!)) throw new IOException("Could not persist core template.");
            if (edit.Inbound is not null || edit.Core is not null || edit.Application is not null || edit.SpeedTest is not null
                || edit.CoreTypes is not null || edit.Routing is not null || edit.NativeTun is not null || edit.SimpleDns is not null || edit.WebDav is not null || edit.TunEnabled is not null)
                if (await store.SaveAsync() != 0) throw new IOException("ServiceLib could not persist settings.");
        }
        public Task RestoreAsync() => store.RestoreAsync(snapshot);
    }
    internal static void ApplyValues(Config config, SettingsEdit edit)
    {
        if (edit.TunEnabled is { } enabled) config.TunModeItem.EnableTun = enabled;
        if (edit.WebDav is { } webDav)
        {
            var normalized = webDav.Normalize();
            config.WebDavItem.Url = normalized.Url;
            config.WebDavItem.UserName = normalized.UserName;
            config.WebDavItem.DirName = normalized.Directory;
            // Missing password means unchanged; an explicit empty value clears it.
            if (normalized.Password is not null) config.WebDavItem.Password = normalized.Password;
        }
        if (edit.SimpleDns is { } simple)
        {
            config.SimpleDNSItem ??= new();
            config.SimpleDNSItem.UseSystemHosts = simple.UseSystemHosts;
            config.SimpleDNSItem.AddCommonHosts = simple.AddCommonHosts;
            config.SimpleDNSItem.FakeIP = simple.FakeIP;
            config.SimpleDNSItem.GlobalFakeIp = simple.GlobalFakeIp;
            config.SimpleDNSItem.FakeIPRange = simple.FakeIPRange;
            config.SimpleDNSItem.BlockBindingQuery = simple.BlockBindingQuery;
            config.SimpleDNSItem.BlockAAAAQuery = simple.BlockAAAAQuery;
            config.SimpleDNSItem.DirectDNS = simple.DirectDNS;
            config.SimpleDNSItem.RemoteDNS = simple.RemoteDNS;
            config.SimpleDNSItem.BootstrapDNS = simple.BootstrapDNS;
            config.SimpleDNSItem.Strategy4Freedom = simple.Strategy4Freedom;
            config.SimpleDNSItem.Strategy4Proxy = simple.Strategy4Proxy;
            config.SimpleDNSItem.Strategy4ProxyDial = simple.Strategy4ProxyDial;
            config.SimpleDNSItem.ServeStale = simple.ServeStale;
            config.SimpleDNSItem.ParallelQuery = simple.ParallelQuery;
            config.SimpleDNSItem.Hosts = simple.Hosts;
            config.SimpleDNSItem.DirectExpectedIPs = simple.DirectExpectedIPs;
            config.SimpleDNSItem.EnableHappyEyeballs = simple.EnableHappyEyeballs;
        }
        if (edit.Inbound is { } inbound) ApplyInbound(config.Inbound[0], inbound);
        if (edit.Core is { } core) ApplyCore(config, core);
        if (edit.NativeTun is { } tun)
        {
            config.TunModeItem.Mtu = tun.Mtu;
            config.TunModeItem.EnableIPv6Address = tun.EnableIPv6Address;
            config.TunModeItem.RouteExcludeAddress = (tun.RouteExcludeAddress ?? []).ToList();
        }
        if (edit.Application is { } app)
        {
            config.GuiItem.EnableStatistics = app.EnableStatistics;
            config.GuiItem.DisplayRealTimeSpeed = app.DisplayRealTimeSpeed;
            config.GuiItem.KeepOlderDedupl = app.KeepOlderDedupl;
            config.GuiItem.AutoUpdateInterval = Math.Max(0, app.GeoAutoUpdateInterval);
            config.GuiItem.RootCertProvider = app.RootCertProvider;
            config.ConstItem.GeoSourceUrl = app.GeoSourceUrl;
            config.ConstItem.RouteRulesTemplateSourceUrl = app.RouteRulesTemplateSourceUrl;
            config.ConstItem.SubConvertUrl = app.SubConvertUrl;
        }
        if (edit.SpeedTest is { } speed)
        {
            config.SpeedTestItem.SpeedTestTimeout = speed.SpeedTestTimeout;
            config.SpeedTestItem.SpeedTestUrl = speed.SpeedTestUrl;
            config.SpeedTestItem.SpeedPingTestUrl = speed.SpeedPingTestUrl;
            config.SpeedTestItem.MixedConcurrencyCount = Math.Max(speed.MixedConcurrencyCount, Global.SpeedTestConcurrencyCountMin);
            config.SpeedTestItem.IPAPIUrl = speed.IPAPIUrl;
            config.SpeedTestItem.UdpTestTarget = speed.UdpTestTarget;
        }
        if (edit.CoreTypes is { } mappings)
        {
            EnsureCoreTypeMappings(config);
            foreach (var mapping in mappings)
            {
                if (!mapping.UsesXray) throw new InvalidOperationException("Only Xray mappings can be persisted.");
                var existing = config.CoreTypeItem.FirstOrDefault(item => (int)item.ConfigType == mapping.Protocol);
                if (existing is not null) existing.CoreType = ECoreType.Xray;
            }
        }
        if (edit.Routing is { } routing) config.RoutingBasicItem.DomainStrategy = routing.Value!;
    }
    internal static void EnsureCoreTypeMappings(Config config)
    {
        config.CoreTypeItem ??= [];
        foreach (var configType in Enum.GetValues<EConfigType>())
            if (config.CoreTypeItem.All(item => item.ConfigType != configType))
                config.CoreTypeItem.Add(new CoreTypeItem { ConfigType = configType, CoreType = ECoreType.Xray });
    }
    internal static string[] NormalizeProtocols(bool enabled, IEnumerable<string>? values) =>
        SettingsPolicy.SniffingProtocols(enabled, values, new InItem().DestOverride ?? []);
    internal static void ApplyInbound(InItem target, InboundSettings input)
    {
        target.LocalPort = input.LocalPort;
        target.SecondLocalPortEnabled = input.SecondLocalPortEnabled;
        target.UdpEnabled = input.UdpEnabled;
        target.SniffingEnabled = input.SniffingEnabled;
        target.DestOverride = NormalizeProtocols(input.SniffingEnabled, input.DestOverride).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        target.RouteOnly = input.RouteOnly;
        target.AllowLANConn = input.AllowLANConn;
        target.NewPort4LAN = input.AllowLANConn && input.NewPort4LAN;
        target.User = input.User?.Trim() ?? string.Empty;
        target.Pass = input.Pass?.Trim() ?? string.Empty;
    }
    private static void ApplyCore(Config config, CoreSettings input)
    {
        config.CoreBasicItem.LogEnabled = input.LogEnabled;
        config.CoreBasicItem.Loglevel = input.Loglevel ?? string.Empty;
        config.CoreBasicItem.DefFingerprint = input.DefFingerprint?.Trim() ?? string.Empty;
        config.CoreBasicItem.DefUserAgent = input.DefUserAgent?.Trim() ?? string.Empty;
        config.CoreBasicItem.SendThrough = input.SendThrough?.Trim();
        config.CoreBasicItem.BindInterface = input.BindInterface?.Trim();
        config.Mux4RayItem.Concurrency = input.Mux4RayConcurrency is > 0 ? input.Mux4RayConcurrency : null;
        config.Mux4RayItem.XudpConcurrency = input.Mux4RayXudpConcurrency is > 0 ? input.Mux4RayXudpConcurrency : null;
        config.Mux4RayItem.XudpProxyUDP443 = input.Mux4RayXudpProxyUDP443;
        config.HysteriaItem.UpMbps = input.Hy2UpMbps;
        config.HysteriaItem.DownMbps = input.Hy2DownMbps;
        config.CoreBasicItem.EnableFragment = input.EnableFragment;
        config.CoreBasicItem.EnableFinalFragment = input.EnableFinalFragment;
        config.Fragment4RayItem ??= new();
        config.Fragment4RayItem.Packets = input.FragmentPackets;
        config.Fragment4RayItem.Lengths = input.FragmentLengths?.ToList() ?? [];
        config.Fragment4RayItem.Delays = input.FragmentDelays?.ToList() ?? [];
        config.Fragment4RayItem.MaxSplit = input.FragmentMaxSplit;
    }

    internal static string Fingerprint(Config config) => System.Text.Json.JsonSerializer.Serialize(new
    {
        Inbound = config.Inbound.Select(item => new
        {
            item.LocalPort,
            Protocol = item.Protocol ?? string.Empty,
            item.UdpEnabled,
            item.SniffingEnabled,
            DestOverride = item.DestOverride ?? [],
            item.RouteOnly,
            item.AllowLANConn,
            item.NewPort4LAN,
            User = item.User ?? string.Empty,
            Pass = item.Pass ?? string.Empty,
            item.SecondLocalPortEnabled,
        }),
        CoreBasic = new
        {
            config.CoreBasicItem.LogEnabled,
            Loglevel = config.CoreBasicItem.Loglevel ?? string.Empty,
            DefFingerprint = config.CoreBasicItem.DefFingerprint ?? string.Empty,
            DefUserAgent = config.CoreBasicItem.DefUserAgent ?? string.Empty,
            SendThrough = config.CoreBasicItem.SendThrough ?? string.Empty,
            BindInterface = config.CoreBasicItem.BindInterface ?? string.Empty,
            config.CoreBasicItem.EnableFragment,
            config.CoreBasicItem.EnableFinalFragment,
        },
        TunMode = config.TunModeItem,
        Mux4Ray = new
        {
            config.Mux4RayItem.Concurrency,
            config.Mux4RayItem.XudpConcurrency,
            XudpProxyUDP443 = config.Mux4RayItem.XudpProxyUDP443 ?? string.Empty,
        },
        config.HysteriaItem.UpMbps,
        config.HysteriaItem.DownMbps,
        Fragment = new
        {
            Packets = config.Fragment4RayItem?.Packets ?? string.Empty,
            Lengths = config.Fragment4RayItem?.Lengths ?? [],
            Delays = config.Fragment4RayItem?.Delays ?? [],
            MaxSplit = config.Fragment4RayItem?.MaxSplit ?? string.Empty,
        },
        config.SimpleDNSItem,
        Routing = new
        {
            DomainStrategy = config.RoutingBasicItem.DomainStrategy ?? string.Empty,
        },
        CoreTypeMapping = config.CoreTypeItem ?? [],
    });

}
