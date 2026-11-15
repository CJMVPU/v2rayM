using V2rayM.Domain.Settings;
using V2rayM.Domain.Backups;

namespace V2rayM.Application.Settings;

public sealed record SettingsEdit(InboundSettings? Inbound = null, CoreSettings? Core = null,
    ApplicationSettings? Application = null, SpeedTestSettings? SpeedTest = null,
    IReadOnlyList<CoreMapping>? CoreTypes = null, RoutingStrategy? Routing = null, NativeTunSettings? NativeTun = null,
    SimpleDnsSettings? SimpleDns = null, DnsProfileSettings? DnsProfile = null, CoreTemplateSettings? CoreTemplate = null, WebDavSettings? WebDav = null,
    bool? TunEnabled = null);

public enum SettingsValidationError
{
    None, NativeTun, Credentials, Port, SniffingProtocols, CoreOptions, LogLevel, CoreNumbers,
    Fragment, Application, SpeedTest, CoreTypes, RoutingStrategy, DnsProfile,
}
public interface ISettingsCapabilities
{
    bool ValidNativeTun(NativeTunSettings input);
    bool ValidSniffingProtocols(IEnumerable<string>? values);
    bool ValidCoreOptions(CoreSettings input);
    bool ValidLogLevel(string? value);
    bool ValidFragment(CoreSettings input);
    bool ValidCertificateProvider(string? value);
    bool ValidCoreMappings(IReadOnlyList<CoreMapping> values);
    bool ValidRoutingStrategy(string? value);
    bool ValidDnsProfile(DnsProfileSettings input);
}
public sealed class SettingsEditValidator(ISettingsCapabilities capabilities)
{
    public SettingsValidationError Validate(SettingsEdit edit)
    {
        if (edit.NativeTun is { } tun && !capabilities.ValidNativeTun(tun)) return SettingsValidationError.NativeTun;
        if (edit.Inbound is { } inbound)
        {
            if (!SettingsPolicy.ValidCredentials(inbound)) return SettingsValidationError.Credentials;
            if (!SettingsPolicy.ValidPort(inbound)) return SettingsValidationError.Port;
            if (!capabilities.ValidSniffingProtocols(inbound.DestOverride)) return SettingsValidationError.SniffingProtocols;
        }
        if (edit.Core is { } core)
        {
            if (!capabilities.ValidCoreOptions(core)) return SettingsValidationError.CoreOptions;
            if (!capabilities.ValidLogLevel(core.Loglevel)) return SettingsValidationError.LogLevel;
            if (!SettingsPolicy.ValidCoreNumbers(core)) return SettingsValidationError.CoreNumbers;
            if (!capabilities.ValidFragment(core)) return SettingsValidationError.Fragment;
        }
        if (edit.Application is { } app && (app.GeoAutoUpdateInterval < 0 || !capabilities.ValidCertificateProvider(app.RootCertProvider)))
            return SettingsValidationError.Application;
        if (edit.SpeedTest is { } speed && !SettingsPolicy.ValidSpeedTest(speed)) return SettingsValidationError.SpeedTest;
        if (edit.CoreTypes is { } mappings && !capabilities.ValidCoreMappings(mappings)) return SettingsValidationError.CoreTypes;
        if (edit.Routing is { } routing && !capabilities.ValidRoutingStrategy(routing.Value)) return SettingsValidationError.RoutingStrategy;
        if (edit.DnsProfile is { } dns && !capabilities.ValidDnsProfile(dns)) return SettingsValidationError.DnsProfile;
        return SettingsValidationError.None;
    }
}

public interface ISettingsEditSession
{
    string CoreFingerprint { get; }
    StatisticsSelection Statistics { get; }
    bool TryApply(SettingsEdit edit);
    Task SaveAsync();
    Task RestoreAsync();
}
public interface ISettingsEditorStore { Task<ISettingsEditSession> CaptureAsync(); }
public interface ISettingsEditEffects
{
    Task RefreshStatisticsAsync();
    void Log(string message);
}
public enum SettingsEditStatus { Saved, Invalid, NotFound, PersistenceFailed, RuntimeApplyFailed }
public sealed record SettingsEditResult(SettingsEditStatus Status, SettingsValidationError Validation = SettingsValidationError.None,
    bool CoreChanged = false, bool ConfigRestored = false, string? ExceptionType = null, string? Detail = null, string? RollbackDetail = null);

public sealed class SettingsEditorService(ISettingsEditorStore store, IMutationScope mutations,
    SettingsEditValidator validator, ISettingsEditEffects effects)
{
    public SettingsValidationError Validate(SettingsEdit edit) => validator.Validate(edit);

    // The caller owns lifecycle serialization. Snapshot, write and persistence
    // compensation share one mutation scope, including single-section edits.
    public async Task<SettingsEditResult> EditAsync(SettingsEdit edit, Func<bool, Task<bool>>? applyRuntime = null)
    {
        var validation = Validate(edit);
        if (validation != SettingsValidationError.None) return new(SettingsEditStatus.Invalid, validation);
        var statisticsChanged = false;
        var result = await mutations.RunAsync(async () =>
        {
            ISettingsEditSession? session = null;
            try
            {
                session = await store.CaptureAsync();
                var beforeCore = session.CoreFingerprint;
                var beforeStatistics = session.Statistics;
                if (!session.TryApply(edit)) return new SettingsEditResult(SettingsEditStatus.NotFound);
                await session.SaveAsync();
                statisticsChanged = beforeStatistics != session.Statistics;
                return new SettingsEditResult(SettingsEditStatus.Saved, CoreChanged: beforeCore != session.CoreFingerprint);
            }
            catch (Exception exception)
            {
                var restored = false;
                string? rollbackDetail = null;
                if (session is not null)
                {
                    try { await session.RestoreAsync(); restored = true; }
                    catch (Exception rollback) { rollbackDetail = rollback.Message; ApplicationDiagnostics.Report(effects.Log, $"Settings persistence rollback failed: {rollback}"); }
                }
                ApplicationDiagnostics.Report(effects.Log, $"Settings persistence failed before runtime apply: {exception}");
                return new SettingsEditResult(SettingsEditStatus.PersistenceFailed, ConfigRestored: restored,
                    ExceptionType: exception.GetType().Name, Detail: exception.Message, RollbackDetail: rollbackDetail);
            }
        });
        if (result.Status != SettingsEditStatus.Saved) return result;
        // Statistics must use the final configuration, including a runtime rollback.
        // It must not refresh early from a configuration that may still be rejected.
        var applied = applyRuntime is null || await applyRuntime(result.CoreChanged);
        if (statisticsChanged)
        {
            try { await effects.RefreshStatisticsAsync(); }
            catch (Exception exception) { ApplicationDiagnostics.Report(effects.Log, $"Statistics reinitialization failed after settings apply: {exception}"); }
        }
        return applied ? result : result with { Status = SettingsEditStatus.RuntimeApplyFailed };
    }
}
