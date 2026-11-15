using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using V2rayM.Domain.Settings;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Settings;

internal interface ISettingsProfileWriter
{
    Task<bool> SaveDnsAsync(DNSItem item);
    Task<bool> SaveTemplateAsync(FullConfigTemplateItem item);
}

internal sealed class ServiceLibConfigurationProfiles(Func<Config> config) : ISettingsProfileWriter
{
    public async Task<bool> SaveDnsAsync(DNSItem item) => await ConfigHandler.SaveDNSItems(config(), item) == 0;
    public async Task<bool> SaveTemplateAsync(FullConfigTemplateItem item) => await ConfigHandler.SaveFullConfigTemplate(config(), item) == 0;
    public static DnsProfileSettings Describe(DNSItem item) => new(item.Remarks, item.Enabled, item.UseSystemHosts,
        item.NormalDNS, item.TunDNS, item.DomainStrategy4Freedom, item.DomainDNSAddress);
    public static CoreTemplateSettings Describe(FullConfigTemplateItem item) => new(item.Remarks, item.Enabled, item.Config,
        item.TunConfig, item.AddProxyOnly, item.ProxyDetour);
    public static DNSItem Apply(DNSItem item, DnsProfileSettings input)
    {
        item.Remarks = input.Remarks ?? item.Remarks;
        item.Enabled = input.Enabled;
        item.UseSystemHosts = input.UseSystemHosts;
        item.NormalDNS = input.NormalDNS;
        item.TunDNS = input.TunDNS;
        item.DomainStrategy4Freedom = input.DomainStrategy4Freedom;
        item.DomainDNSAddress = input.DomainDNSAddress;
        return item;
    }
    public static FullConfigTemplateItem Apply(FullConfigTemplateItem item, CoreTemplateSettings input)
    {
        item.Remarks = input.Remarks ?? item.Remarks;
        item.Enabled = input.Enabled;
        item.Config = input.Config;
        item.TunConfig = input.TunConfig;
        item.AddProxyOnly = input.AddProxyOnly;
        item.ProxyDetour = input.ProxyDetour;
        return item;
    }
    public static async Task<IReadOnlyList<DnsProfileView>> ReadDnsAsync() =>
        (await AppManager.Instance.DNSItems() ?? []).Select(ToView).ToArray();
    public static async Task<IReadOnlyList<CoreConfigTemplateView>> ReadTemplatesAsync() =>
        (await AppManager.Instance.FullConfigTemplateItem() ?? []).Select(ToView).ToArray();
    public static DnsProfileView ToView(DNSItem item) => new(item.Id, item.Remarks, item.Enabled, item.CoreType,
        item.UseSystemHosts, item.NormalDNS, item.TunDNS, item.DomainStrategy4Freedom, item.DomainDNSAddress);
    public static CoreConfigTemplateView ToView(FullConfigTemplateItem item) => new(item.Id, item.Remarks, item.Enabled,
        item.CoreType, item.Config, item.TunConfig, item.AddProxyOnly, item.ProxyDetour);
}
