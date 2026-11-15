using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Handler;
using ServiceLib.Helper;
using ServiceLib.Manager;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Adapters.Settings;

// Full upstream documents stay here; the application coordinates their transaction.
internal sealed class ServiceLibRegionalPresetStore(IRuntimeConfigStore store)
{
    // Include only state used/overwritten by staging. Unrelated application edits
    // do not invalidate downloads; route and DNS identities and hidden fields do.
    internal static string Fingerprint(RuntimeConfigSnapshot snapshot) => JsonUtils.Serialize(new
    {
        snapshot.Config.ConstItem.GeoSourceUrl,
        snapshot.Config.ConstItem.RouteRulesTemplateSourceUrl,
        snapshot.Config.SimpleDNSItem,
        snapshot.Config.RoutingBasicItem,
        Dns = snapshot.Dns.OrderBy(item => item.Id, StringComparer.Ordinal),
        Routing = snapshot.Routing.OrderBy(item => item.Id, StringComparer.Ordinal),
    }, false);

    public async Task ApplyAsync(RegionalPresetStage stage, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        store.Current.ConstItem.GeoSourceUrl = stage.GeoSourceUrl;
        store.Current.ConstItem.RouteRulesTemplateSourceUrl = stage.RouteRulesTemplateSourceUrl;
        store.Current.SimpleDNSItem = stage.SimpleDnsItem;

        if (stage.Preset == EPresetType.Default)
        {
            await SQLiteHelper.Instance.DeleteAllAsync<DNSItem>();
            foreach (var item in stage.DnsItems)
            {
                if (await ConfigDbHandler.SaveDNSItems(store.Current, item) != 0)
                {
                    throw new IOException($"The {item.CoreType} DNS profile could not be saved.");
                }
            }

            // Default routing uses embedded data only; this call performs no network I/O
            // because the route template source was cleared in the staged plan.
            if (await ConfigDbHandler.InitRouting(store.Current, false) != 0)
            {
                throw new IOException("The built-in routing profiles could not be initialized.");
            }
        }
        else
        {
            foreach (var item in stage.DnsItems)
            {
                if (await ConfigDbHandler.SaveDNSItems(store.Current, item) != 0)
                {
                    throw new IOException($"The {item.CoreType} DNS profile could not be saved.");
                }
            }

            foreach (var itemId in stage.Routing.RemoveItemIds ?? [])
            {
                var item = await ConfigDbQuery.GetRoutingItem(itemId);
                if (item is not null)
                {
                    await ConfigDbHandler.RemoveRoutingItem(item);
                }
            }

            if (stage.Routing.ClearLegacyRoutingIndex)
            {
                store.Current.RoutingBasicItem.RoutingIndexId = string.Empty;
            }

            var currentRoutes = await ConfigDbQuery.RoutingItems() ?? [];
            var hasVersion = stage.Routing.TemplateVersion is { Length: > 0 } version
                && currentRoutes.Any(item => item.Remarks?.StartsWith(version, StringComparison.Ordinal) == true);
            var builtinFallbackAlreadyInitialized = stage.Routing.IsBuiltinFallback && currentRoutes.Count > 0;
            if (!hasVersion && !builtinFallbackAlreadyInitialized)
            {
                var nextSort = currentRoutes.Count;
                foreach (var item in stage.Routing.Items)
                {
                    item.Sort = ++nextSort;
                    if (await ConfigDbHandler.AddBatchRoutingRules(item, item.RuleSet ?? "[]") != 0)
                    {
                        throw new IOException($"The routing profile '{item.Remarks}' could not be saved.");
                    }
                }

                var defaultItem = stage.Routing.DefaultRemarks is { } remarks
                    ? stage.Routing.Items.FirstOrDefault(item => item.Remarks == remarks)
                    : null;
                if (defaultItem is not null && await ConfigDbHandler.SetDefaultRouting(store.Current, defaultItem) != 0)
                {
                    throw new IOException("The first staged routing profile could not be activated.");
                }
            }

            if (stage.Routing.ExistingDefaultItemId is { } existingDefaultId)
            {
                var existingDefault = currentRoutes.FirstOrDefault(item => item.Id == existingDefaultId);
                if (existingDefault is not null && !existingDefault.IsActive
                    && await ConfigDbHandler.SetDefaultRouting(store.Current, existingDefault) != 0)
                {
                    throw new IOException("The migrated default routing profile could not be activated.");
                }
            }
        }

        token.ThrowIfCancellationRequested();
        if (await store.SaveAsync() != 0) throw new IOException("Regional preset configuration could not be saved.");
        token.ThrowIfCancellationRequested();
    }
}
