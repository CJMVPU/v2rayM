using System.Net;
using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Handler;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Dto;
using ServiceLib.Models.Entities;

namespace v2rayN.WebAPI.Adapters.Settings;

internal sealed record RegionalRoutingPlan(
    string? TemplateVersion,
    IReadOnlyList<RoutingItem> Items,
    string? DefaultRemarks = null,
    IReadOnlyList<string>? RemoveItemIds = null,
    string? ExistingDefaultItemId = null,
    bool ClearLegacyRoutingIndex = false,
    bool IsBuiltinFallback = false);

internal sealed record RegionalPresetStage(
    EPresetType Preset,
    string GeoSourceUrl,
    string RouteRulesTemplateSourceUrl,
    SimpleDNSItem SimpleDnsItem,
    IReadOnlyList<DNSItem> DnsItems,
    RegionalRoutingPlan Routing,
    string? ExpectedState = null);

internal sealed class RegionalPresetStager(
    Func<string, IWebProxy?, CancellationToken, Task<string?>> download,
    TimeSpan? timeout = null)
{
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(30);
    private readonly TimeSpan _timeout = timeout ?? DefaultTimeout;

    public async Task<RegionalPresetStage> StageAsync(
        EPresetType preset,
        IReadOnlyList<DNSItem> existingDnsItems,
        IReadOnlyList<RoutingItem> existingRoutingItems,
        IWebProxy? proxy,
        CancellationToken cancellationToken,
        string? legacyRoutingIndexId = null)
    {
        if (preset == EPresetType.Default)
        {
            return new(
                preset,
                string.Empty,
                string.Empty,
                ConfigDbHandler.InitBuiltinSimpleDNS(),
                [CreateDefaultDns(ECoreType.Xray, "V2ray")],
                new(null, []));
        }

        var sourceIndex = preset switch
        {
            EPresetType.Russia => 1,
            EPresetType.Iran => 2,
            _ => throw new ArgumentOutOfRangeException(nameof(preset), preset, "Unsupported regional preset."),
        };
        var xrayItem = existingDnsItems.FirstOrDefault(item => item.CoreType == ECoreType.Xray)
            ?? throw new InvalidOperationException("The Xray DNS profile is missing.");
        var dnsBaseUrl = Global.DNSTemplateSources[sourceIndex];
        var routeTemplateUrl = Global.RoutingRulesSources[sourceIndex];

        var xrayTask = StageDnsProfileAsync(ECoreType.Xray, xrayItem, dnsBaseUrl + "v2ray.json", proxy, cancellationToken);
        var simpleDnsTask = StageSimpleDnsAsync(dnsBaseUrl + "simple_dns.json", proxy, cancellationToken);
        var routingTask = StageRoutingAsync(routeTemplateUrl, existingRoutingItems, legacyRoutingIndexId, proxy, cancellationToken);
        await Task.WhenAll(xrayTask, simpleDnsTask, routingTask);

        var xrayDns = await xrayTask;
        var simpleDns = await simpleDnsTask;
        if (simpleDns.UsedFallback)
        {
            // Desktop enables both Core-specific DNS profiles when simple_dns.json is unavailable.
            xrayDns.Enabled = true;
        }

        return new(
            preset,
            Global.GeoFilesSources[sourceIndex],
            routeTemplateUrl,
            simpleDns.Item,
            [xrayDns],
            await routingTask);
    }

    private async Task<DNSItem> StageDnsProfileAsync(
        ECoreType coreType,
        DNSItem existing,
        string url,
        IWebProxy? proxy,
        CancellationToken cancellationToken)
    {
        var content = await TryDownloadAsync(url, proxy, cancellationToken);
        var template = content is null ? null : JsonUtils.Deserialize<DNSItem>(content);
        if (template is null)
        {
            // ConfigDbHandler.GetExternalDNSItem returns the current DNS item when the
            // template cannot be downloaded or parsed.
            return CloneDnsItem(existing);
        }

        var normalDnsTask = string.IsNullOrWhiteSpace(template.NormalDNS)
            ? Task.FromResult<string?>(null)
            : TryDownloadAsync(template.NormalDNS, proxy, cancellationToken);
        var tunDnsTask = string.IsNullOrWhiteSpace(template.TunDNS)
            ? Task.FromResult<string?>(null)
            : TryDownloadAsync(template.TunDNS, proxy, cancellationToken);
        await Task.WhenAll(normalDnsTask, tunDnsTask);

        // Desktop keeps a successfully downloaded template even when its referenced
        // NormalDNS/TunDNS resource fails; TryDownloadString then leaves that field empty.
        if (!string.IsNullOrWhiteSpace(template.NormalDNS))
        {
            template.NormalDNS = await normalDnsTask ?? string.Empty;
        }
        if (!string.IsNullOrWhiteSpace(template.TunDNS))
        {
            template.TunDNS = await tunDnsTask ?? string.Empty;
        }

        template.Id = existing.Id;
        template.Remarks = existing.Remarks;
        template.Enabled = existing.Enabled;
        template.CoreType = coreType;
        return template;
    }

    private async Task<(SimpleDNSItem Item, bool UsedFallback)> StageSimpleDnsAsync(
        string url,
        IWebProxy? proxy,
        CancellationToken cancellationToken)
    {
        var content = await TryDownloadAsync(url, proxy, cancellationToken);
        var template = content is null ? null : JsonUtils.Deserialize<SimpleDNSItem>(content);
        return template is null
            ? (ConfigDbHandler.InitBuiltinSimpleDNS(), true)
            : (template, false);
    }

    private async Task<RegionalRoutingPlan> StageRoutingAsync(
        string url,
        IReadOnlyList<RoutingItem> existingItems,
        string? legacyRoutingIndexId,
        IWebProxy? proxy,
        CancellationToken cancellationToken)
    {
        var content = await TryDownloadAsync(url, proxy, cancellationToken);
        var template = content is null ? null : JsonUtils.Deserialize<RoutingTemplate>(content);
        if (template is null || string.IsNullOrWhiteSpace(template.Version) || template.RoutingItems is null)
        {
            return StageBuiltinRouting(existingItems, legacyRoutingIndexId);
        }

        if (existingItems.Any(item => item.Remarks?.StartsWith(template.Version, StringComparison.Ordinal) == true))
        {
            // Importing an already-present template version must not change the active route.
            return new(template.Version, []);
        }

        var stagedTasks = template.RoutingItems
            .Select(sourceItem => StageRoutingItemAsync(sourceItem, template.Version, proxy, cancellationToken))
            .ToArray();
        var stagedResults = await Task.WhenAll(stagedTasks);
        var stagedItems = stagedResults.Where(item => item is not null).Cast<RoutingItem>().ToArray();
        for (var index = 0; index < stagedItems.Length; index++)
        {
            stagedItems[index].Sort = existingItems.Count + index + 1;
        }

        return new(template.Version, stagedItems, stagedItems.FirstOrDefault()?.Remarks);
    }

    private async Task<RoutingItem?> StageRoutingItemAsync(
        RoutingItem? sourceItem,
        string templateVersion,
        IWebProxy? proxy,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (sourceItem is null || (string.IsNullOrWhiteSpace(sourceItem.Url) && string.IsNullOrWhiteSpace(sourceItem.RuleSet)))
        {
            return null;
        }

        var rulesContent = !string.IsNullOrWhiteSpace(sourceItem.RuleSet)
            ? sourceItem.RuleSet
            : await TryDownloadAsync(sourceItem.Url, proxy, cancellationToken);
        var rules = rulesContent is null ? null : JsonUtils.Deserialize<List<RulesItem>>(rulesContent);
        if (rules is null)
        {
            // Desktop skips an entry whose URL returns no content. Invalid rule JSON is
            // likewise not a usable AddBatchRoutingRules payload, so skip only that entry.
            return null;
        }

        var item = JsonUtils.DeepCopy(sourceItem);
        if (item is null)
        {
            return null;
        }
        item.Id = string.Empty;
        item.Remarks = $"{templateVersion}-{item.Remarks}";
        item.Enabled = true;
        item.Url = string.Empty;
        item.IsActive = false;
        item.RuleNum = rules.Count;
        item.RuleSet = JsonUtils.Serialize(rules, false);
        return item;
    }

    private static RegionalRoutingPlan StageBuiltinRouting(
        IReadOnlyList<RoutingItem> existingItems,
        string? legacyRoutingIndexId)
    {
        // Match InitBuiltinRouting's one-time locked-profile removal and migration of
        // RoutingIndexId, while keeping all database writes in the later apply phase.
        var lockedItem = existingItems.FirstOrDefault(item => item.Locked);
        var items = lockedItem is null
            ? existingItems.ToList()
            : existingItems.Where(item => item.Id != lockedItem.Id).ToList();
        var removeIds = lockedItem is null || string.IsNullOrEmpty(lockedItem.Id)
            ? Array.Empty<string>()
            : [lockedItem.Id];
        var clearLegacyIndex = !string.IsNullOrWhiteSpace(legacyRoutingIndexId);

        if (items.Count > 0)
        {
            var migrationTarget = clearLegacyIndex
                ? items.FirstOrDefault(item => item.Id == legacyRoutingIndexId)
                : null;
            return new(
                null,
                [],
                RemoveItemIds: removeIds,
                ExistingDefaultItemId: migrationTarget is { IsActive: false } ? migrationTarget.Id : null,
                ClearLegacyRoutingIndex: clearLegacyIndex,
                IsBuiltinFallback: true);
        }

        var defaults = new[]
        {
            (Name: "绕过大陆(Whitelist)", Resource: "white"),
            (Name: "黑名单(Blacklist)", Resource: "black"),
            (Name: "全局(Global)", Resource: "global"),
        };
        var builtins = defaults.Select((entry, index) =>
        {
            var rulesContent = EmbedUtils.GetEmbedText(Global.CustomRoutingFileName + entry.Resource);
            var rules = JsonUtils.Deserialize<List<RulesItem>>(rulesContent)
                ?? throw new InvalidDataException($"The built-in routing rules '{entry.Resource}' are invalid.");
            return new RoutingItem
            {
                Remarks = $"V4-{entry.Name}",
                Url = string.Empty,
                RuleNum = rules.Count,
                RuleSet = JsonUtils.Serialize(rules, false),
                Enabled = true,
                Sort = index + 1,
            };
        }).ToArray();

        return new(
            null,
            builtins,
            builtins[0].Remarks,
            removeIds,
            ClearLegacyRoutingIndex: clearLegacyIndex,
            IsBuiltinFallback: true);
    }

    private async Task<string?> TryDownloadAsync(string url, IWebProxy? proxy, CancellationToken cancellationToken)
    {
        try
        {
            return await DownloadRequiredAsync(url, proxy, cancellationToken);
        }
        catch (Exception exception) when (IsFallbackFailure(exception, cancellationToken))
        {
            return null;
        }
    }

    private async Task<string> DownloadRequiredAsync(string url, IWebProxy? proxy, CancellationToken cancellationToken)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_timeout);
        try
        {
            var content = await download(url, proxy, timeoutCts.Token);
            if (string.IsNullOrWhiteSpace(content))
            {
                throw new InvalidDataException($"The download returned no content: {url}");
            }
            return content;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new TimeoutException($"The download exceeded {_timeout.TotalSeconds:0.###} seconds: {url}");
        }
    }

    private static bool IsFallbackFailure(Exception exception, CancellationToken cancellationToken) =>
        !cancellationToken.IsCancellationRequested
        && exception is not OperationCanceledException
        && exception is TimeoutException or HttpRequestException or WebException or IOException or InvalidDataException;

    private static DNSItem CloneDnsItem(DNSItem item) =>
        JsonUtils.DeepCopy(item) ?? throw new InvalidOperationException("A DNS profile could not be copied for regional preset staging.");

    private static DNSItem CreateDefaultDns(ECoreType coreType, string remarks) => new()
    {
        Remarks = remarks,
        CoreType = coreType,
        Enabled = false,
    };
}
