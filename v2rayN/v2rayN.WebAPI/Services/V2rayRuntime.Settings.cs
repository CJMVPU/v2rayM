using v2rayN.WebAPI.Adapters.Settings;
using V2rayM.Domain.Settings;
using V2rayM.Application.Settings;
using V2rayM.Application.Routing;
using V2rayM.Domain.Routing;
using v2rayN.WebAPI.Adapters.Routing;
using V2rayM.Domain.Runtime;
using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Handler;
using ServiceLib.Helper;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.CoreConfigs;
using ServiceLib.Models.Entities;
using ServiceLib.Services;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{

    private static readonly ServiceLibSettingsCapabilities SettingsCapabilities = new();
    private static readonly EConfigType[] WebEditableCoreTypes = ServiceLibSettingsCapabilities.EditableCoreTypes;

    public Task<WebSettingsView> GetSettingsAsync()
    {
        var inbound = Config.Inbound[0];
        return Task.FromResult(new WebSettingsView(
            new InboundSettingsView(
                inbound.LocalPort,
                inbound.SecondLocalPortEnabled,
                inbound.UdpEnabled,
                inbound.SniffingEnabled,
                inbound.DestOverride?.ToArray() ?? [],
                inbound.RouteOnly,
                inbound.AllowLANConn,
                inbound.NewPort4LAN,
                inbound.User,
                inbound.Pass),
            new CoreSettingsView(
                Config.CoreBasicItem.LogEnabled,
                Config.CoreBasicItem.Loglevel,
                Config.CoreBasicItem.DefFingerprint,
                Config.CoreBasicItem.DefUserAgent,
                Config.CoreBasicItem.SendThrough,
                Config.CoreBasicItem.BindInterface,
                Config.Mux4RayItem.Concurrency,
                Config.Mux4RayItem.XudpConcurrency,
                Config.Mux4RayItem.XudpProxyUDP443,
                Config.HysteriaItem.UpMbps,
                Config.HysteriaItem.DownMbps,
                Config.CoreBasicItem.EnableFragment,
                Config.CoreBasicItem.EnableFinalFragment,
                Config.Fragment4RayItem?.Packets,
                Config.Fragment4RayItem?.Lengths?.ToArray() ?? [],
                Config.Fragment4RayItem?.Delays?.ToArray() ?? [],
                Config.Fragment4RayItem?.MaxSplit),
            new AppSettingsView(
                Config.GuiItem.EnableStatistics,
                Config.GuiItem.DisplayRealTimeSpeed,
                Config.GuiItem.KeepOlderDedupl,
                Config.GuiItem.AutoUpdateInterval,
                Config.GuiItem.RootCertProvider,
                Config.ConstItem.GeoSourceUrl,
                Config.ConstItem.RouteRulesTemplateSourceUrl,
                Config.ConstItem.SubConvertUrl),
            new SpeedTestSettingsView(
                Config.SpeedTestItem.SpeedTestTimeout,
                Config.SpeedTestItem.SpeedTestUrl,
                Config.SpeedTestItem.SpeedPingTestUrl,
                Config.SpeedTestItem.MixedConcurrencyCount,
                Config.SpeedTestItem.IPAPIUrl,
                Config.SpeedTestItem.UdpTestTarget),
            Config.RoutingBasicItem.DomainStrategy,
            Config.CoreTypeItem
                .Where(item => WebEditableCoreTypes.Contains(item.ConfigType))
                .Select(item => new CoreTypeMapping(item.ConfigType, ECoreType.Xray))
                .ToArray(),
            GetWebSettingsOptions(),
            ShouldShowIpInfoColumn(Config.SpeedTestItem.IPAPIUrl, Config.UiItem.HideColumnIpInfo)));
    }

    public static WebSettingsOptionsView GetWebSettingsOptions() => EditorOptionsCatalog.GetWebSettingsOptions();
    public static WebEditorOptionsView GetEditorOptions() => EditorOptionsCatalog.GetEditorOptions();
    public static DnsEditorOptionsView GetDnsEditorOptions() => EditorOptionsCatalog.GetDnsEditorOptions();

    public IReadOnlyList<DnsDefaultProfileView> GetDefaultDnsProfiles() =>
    [
        new(ECoreType.Xray,
            EmbedUtils.GetEmbedText(Global.DNSV2rayNormalFileName),
            EmbedUtils.GetEmbedText(Global.DNSV2rayNormalFileName)),
    ];

    public Task<OperationView> ApplySettingsAsync(SettingsApplyInput input) =>
        EditCoreSettingsAsync("all-settings", SettingsContractMapper.Map(input));

    public Task<OperationView> UpdateInboundSettingsAsync(InboundSettingsInput input) =>
        EditCoreSettingsAsync("inbound", new(Inbound: SettingsContractMapper.Map(input)));

    public Task<OperationView> UpdateCoreSettingsAsync(CoreSettingsInput input) =>
        EditCoreSettingsAsync("core", new(Core: SettingsContractMapper.Map(input)));

    public Task<OperationView> UpdateAppSettingsAsync(AppSettingsInput input) =>
        EditPassiveSettingsAsync("application", new(Application: SettingsContractMapper.Map(input)), ApiMessageKeys.CommonSaved);

    public Task<OperationView> UpdateSpeedTestSettingsAsync(SpeedTestSettingsInput input) =>
        EditPassiveSettingsAsync("speedtest", new(SpeedTest: SettingsContractMapper.Map(input)), ApiMessageKeys.SpeedTestSettingsSaved);

    public Task<OperationView> UpdateCoreTypeMappingsAsync(IEnumerable<CoreTypeMapping> mappings) =>
        EditCoreSettingsAsync("core-types", new(CoreTypes: SettingsContractMapper.Map(mappings)));

    public Task<OperationView> UpdateRoutingStrategiesAsync(RoutingSettingsInput input) =>
        EditCoreSettingsAsync("routing", new(Routing: new(input.DomainStrategy)));

    private void EnsureCoreTypeMappings() => ServiceLibSettingsEditor.EnsureCoreTypeMappings(Config);

    private async Task<OperationView> EditCoreSettingsAsync(string section, SettingsEdit edit, object? data = null, string? errorSection = null)
    {
        var validation = _settingsEditor.Validate(edit);
        if (validation != SettingsValidationError.None) return SettingsContractMapper.ValidationFailure(validation, errorSection ?? section);
        await using var context = await BeginCoreSettingsApplyAsync();
        if (context.Failure is { } failure) return failure;
        OperationView? applied = null;
        var result = await _settingsEditor.EditAsync(edit, async changed =>
        {
            applied = await CompleteCoreAffectingChangeAsync(section, changed, context, data: data);
            return applied.Success;
        });
        return applied ?? SettingsContractMapper.Failure(result, errorSection ?? section, data);
    }

    private Task<OperationView> EditPassiveSettingsAsync(string section, SettingsEdit edit, string successMessage) =>
        _coreLifecycle.ExecuteAsync(async () =>
        {
            var result = await _settingsEditor.EditAsync(edit);
            if (result.Status != SettingsEditStatus.Saved) return SettingsContractMapper.Failure(result, section);
            _events.Publish("settings-changed", new { section, restartRequired = false });
            return OperationView.Ok(successMessage);
        }, CancellationToken.None);

    public Task<SimpleDNSItem> GetSimpleDNSAsync() => Task.FromResult(Config.SimpleDNSItem);

    public Task<OperationView> UpdateSimpleDNSAsync(SimpleDNSItem input) =>
        EditCoreSettingsAsync("dns", new(SimpleDns: SettingsContractMapper.Map(input)));

    public Task<IReadOnlyList<DnsProfileView>> GetDnsProfilesAsync() => ServiceLibConfigurationProfiles.ReadDnsAsync();

    public Task<OperationView> UpdateDnsProfileAsync(ECoreType coreType, DnsProfileInput input) =>
        coreType != ECoreType.Xray
            ? Task.FromResult(OperationView.Fail("dns_profile_invalid", ApiMessageKeys.CommonInvalidInput))
            : EditCoreSettingsAsync("dns", new(DnsProfile: SettingsContractMapper.Map(input)),
                new { coreType = coreType.ToString() }, "dns-profile");

    internal static DnsProfileView ToDnsProfileView(DNSItem item) => ServiceLibConfigurationProfiles.ToView(item);

    internal static DNSItem ApplyDnsProfileInput(DNSItem current, ECoreType coreType, DnsProfileInput input) =>
        ServiceLibConfigurationProfiles.Apply(JsonUtils.DeepCopy(current)!, SettingsContractMapper.Map(input));

    internal static bool IsValidCustomDns(ECoreType coreType, string? content) => ServiceLibSettingsCapabilities.ValidCustomDns(content);

    public Task<IReadOnlyList<RoutingItem>> GetRoutingProfilesAsync() => _routingSettings.GetRoutingProfilesAsync();
    public Task<OperationView> SaveRoutingProfileAsync(RoutingItem input, string? routingId = null) => _routingSettings.SaveRoutingProfileAsync(input, routingId);
    public Task<OperationView> DeleteRoutingProfileAsync(string id) => _routingSettings.DeleteRoutingProfileAsync(id);
    public Task<OperationView> ActivateRoutingProfileAsync(string id) => _routingSettings.ActivateRoutingProfileAsync(id);
    public Task<IReadOnlyList<RulesItem>> GetRoutingRulesAsync(string id) => _routingSettings.GetRoutingRulesAsync(id);
    public Task<OperationView> SaveRoutingRulesAsync(string id, IEnumerable<RulesItem> rules) => _routingSettings.SaveRoutingRulesAsync(id, rules);
    public Task<OperationView> ImportRoutingRulesAsync(string id, RouteRulesImportInput input) => _routingSettings.ImportRoutingRulesAsync(id, input);
    public Task<OperationView> ImportRoutingRulesFromUrlAsync(string id, bool append, CancellationToken token) => _routingSettings.ImportRoutingRulesFromUrlAsync(id, append, token);
    public Task<OperationView> MoveRoutingRuleAsync(string id, string ruleId, EMove direction, int position) => _routingSettings.MoveRoutingRuleAsync(id, ruleId, direction, position);
    public Task<OperationView> DeleteRoutingRuleAsync(string id, string ruleId) => _routingSettings.DeleteRoutingRuleAsync(id, ruleId);
    public Task<OperationView> ImportRoutingProfilesAsync() => _routingSettings.ImportRoutingProfilesAsync();

    public Task<IReadOnlyList<CoreConfigTemplateView>> GetFullConfigTemplatesAsync() => ServiceLibConfigurationProfiles.ReadTemplatesAsync();

    internal static CoreConfigTemplateView ToCoreConfigTemplateView(FullConfigTemplateItem item) => ServiceLibConfigurationProfiles.ToView(item);

    internal static FullConfigTemplateItem ApplyCoreConfigTemplateInput(FullConfigTemplateItem current,
        ECoreType coreType, CoreConfigTemplateInput input) =>
        ServiceLibConfigurationProfiles.Apply(JsonUtils.DeepCopy(current)!, SettingsContractMapper.Map(input));

    public Task<OperationView> SaveFullConfigTemplateAsync(ECoreType coreType, CoreConfigTemplateInput input) =>
        coreType != ECoreType.Xray
            ? Task.FromResult(OperationView.Fail("core_template_invalid", ApiMessageKeys.CommonInvalidInput))
            : EditCoreSettingsAsync("core-template", new(CoreTemplate: SettingsContractMapper.Map(input)),
                new { coreType = coreType.ToString() });

    internal static bool ShouldShowIpInfoColumn(string? ipApiUrl, bool hideColumnIpInfo) =>
        !string.IsNullOrEmpty(ipApiUrl) && !hideColumnIpInfo;

    internal static bool ValidLanCredentials(InboundSettingsInput input) => SettingsPolicy.ValidCredentials(SettingsContractMapper.Map(input));
    internal static void ApplyInboundSettings(InItem target, InboundSettingsInput input) =>
        ServiceLibSettingsEditor.ApplyInbound(target, SettingsContractMapper.Map(input));
    internal static string[] NormalizeDestOverride(bool willEnableSniffing, IEnumerable<string>? destOverride) =>
        ServiceLibSettingsEditor.NormalizeProtocols(willEnableSniffing, destOverride);

    public async Task<OperationView> ClearStatisticsAsync()
    {
        await _mutations.RunAsync(() => StatisticsManager.Instance.ClearAllServerStatistics());
        _trafficWindow.Clear();
        _events.Publish("traffic", null!);
        _events.Publish("profiles-changed", new { subscriptionId = Config.SubIndexId });
        return OperationView.Ok(ApiMessageKeys.CommonDeleted);
    }

    public Task<IReadOnlyList<string>> GetRunningOperationsAsync()
    {
        var operations = GetRunningSubscriptionUpdates().ToList();
        if (_speedTests.IsRunning)
        {
            operations.Add("speedtest");
        }
        operations.AddRange(GetRunningCoreUpdateOperations());
        if (CurrentCoreRuntime.State != CoreRuntimeState.Stopped)
        {
            operations.Add("core");
        }
        return Task.FromResult<IReadOnlyList<string>>(operations);
    }

    internal static bool IsWebEditableCoreType(EConfigType configType) => WebEditableCoreTypes.Contains(configType);
    internal static bool AreWebCoreTypeMappingsValid(IReadOnlyCollection<CoreTypeMapping> mappings) =>
        SettingsCapabilities.ValidCoreMappings(SettingsContractMapper.Map(mappings));
    internal static bool AreDestOverrideProtocolsValid(IEnumerable<string>? protocols) => SettingsCapabilities.ValidSniffingProtocols(protocols);
    internal static bool IsRootCertProviderValid(string? provider) => SettingsCapabilities.ValidCertificateProvider(provider);
    internal static bool AreCoreSettingsOptionsValid(CoreSettingsInput input) => SettingsCapabilities.ValidCoreOptions(SettingsContractMapper.Map(input));

    internal static bool AreRoutingProfileStrategiesValid(string? domainStrategy) =>
        Global.DomainStrategies.AppendEmpty().Contains(domainStrategy ?? string.Empty);

    private async Task<OperationView> CompleteCoreAffectingChangeAsync(
        string section,
        bool changed,
        CoreSettingsApplyContext context,
        string successMessageKey = ApiMessageKeys.CommonSaved,
        object? data = null,
        Func<Task>? beforeRollback = null)
    {
        var applied = await _settingsApply.CompleteAsync(new CoreSettingsRuntimeAdapter(this), section, changed,
            code => RollBackCoreSettingsAsync(context, code, beforeRollback));
        if (!applied.Success)
        {
            var rollback = applied.Rollback!;
            return CreateSettingsApplyFailure(section, data, applied.FailureCode, ApiMessageKeys.SettingsCoreApplyFailed,
                rollback.ConfigRestored, rollback.RolledBack, rollback.OldRuntimeRestored, rollback.Detail);
        }
        var restarted = applied.Restarted;

        _events.Publish("settings-changed", new { section, restartRequired = false, coreRestarted = restarted });
        var resultData = ToResultDictionary(data);
        resultData["changed"] = changed;
        resultData["coreRestarted"] = restarted;
        resultData["restartRequired"] = false;
        return OperationView.Ok(restarted ? ApiMessageKeys.CoreRestarted : successMessageKey, resultData);
    }

    private Task<CoreSettingsApplyContext> BeginCoreSettingsApplyAsync(CancellationToken cancellationToken = default) =>
        _settingsTransaction.BeginAsync(() => CurrentCoreRuntime, () => HasTrackedCoreProcesses, cancellationToken);

    private Task<SettingsRollbackResult> RollBackCoreSettingsAsync(
        CoreSettingsApplyContext context, string failureCode, Func<Task>? beforeRuntimeRestore = null) =>
        _settingsRecovery.RestoreAsync(new CoreSettingsRuntimeAdapter(this, context), context.HadActiveChild,
            failureCode, beforeRuntimeRestore);

    private OperationView CreateSettingsApplyFailure(
        string section,
        object? data,
        string? failureCode,
        string messageKey,
        bool configRestored,
        bool rolledBack,
        bool oldRuntimeRestored,
        string? rollbackDetail)
    {
        var runtime = CurrentCoreRuntime;
        var failureData = ToResultDictionary(data);
        failureData["section"] = section;
        failureData["configSaved"] = !configRestored;
        failureData["configRestored"] = configRestored;
        failureData["restartRequired"] = true;
        failureData["rolledBack"] = rolledBack;
        failureData["oldRuntimeRestored"] = oldRuntimeRestored;
        failureData["runtimeState"] = runtime.State.ToString().ToLowerInvariant();
        failureData["configuredProxyPort"] = Config.Inbound.FirstOrDefault()?.LocalPort;
        failureData["runningProxyPort"] = runtime.ProxyPort;
        failureData["coreResultCode"] = failureCode;
        failureData["detail"] = runtime.LastFailure;
        failureData["rollbackDetail"] = rollbackDetail;
        _events.Publish("settings-changed", new { section, restartRequired = true, restartFailed = true, rolledBack, oldRuntimeRestored });
        return OperationView.Fail("settings_core_apply_failed", messageKey, failureData);
    }

    private static Dictionary<string, object?> ToResultDictionary(object? data)
    {
        if (data is IReadOnlyDictionary<string, object?> readOnly)
        {
            return new Dictionary<string, object?>(readOnly, StringComparer.Ordinal);
        }
        if (data is IDictionary<string, object?> mutable)
        {
            return new Dictionary<string, object?>(mutable, StringComparer.Ordinal);
        }

        var result = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (data is not null)
        {
            foreach (var property in data.GetType().GetProperties())
            {
                result[property.Name] = property.GetValue(data);
            }
        }
        return result;
    }

}
