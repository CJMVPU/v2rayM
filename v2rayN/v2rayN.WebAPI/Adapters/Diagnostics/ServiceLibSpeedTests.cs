using ServiceLib.Enums;
using ServiceLib.Handler.Builder;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using ServiceLib.Services;
using V2rayM.Application.Diagnostics;
using V2rayM.Domain.Diagnostics;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Diagnostics;

internal sealed class ServiceLibSpeedTests(Func<Config> config, Services.EventHub events, Action<string> log)
    : ISpeedTestSource, ISpeedTestEvents
{
    public async Task<ISpeedTestBatch> PrepareAsync(IReadOnlyList<string>? ids)
    {
        var profiles = ids is { Count: > 0 } ? await ConfigDbQuery.GetProfileItemsOrderedByIndexIds(ids.ToArray())
            : await ConfigDbQuery.ProfileItems(config().SubIndexId ?? string.Empty) ?? [];
        return new Batch(profiles, () => new SpeedtestService(config(), result =>
        {
        int? delay = int.TryParse(result.Delay, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var parsedDelay)
            ? parsedDelay
            : null;
        decimal? speed = decimal.TryParse(result.Speed, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out var parsedSpeed)
            ? parsedSpeed
            : null;
        events.Publish("speedtest-result", new
        {
            code = ApiMessageKeys.SpeedTestResult,
            messageKey = ApiMessageKeys.SpeedTestResult,
            indexId = result.IndexId,
            delay,
            speed,
            ipInfo = result.IpInfo,
            rawResult = delay is null && speed is null ? (result.Delay ?? result.Speed) : null,
        });
        if (!string.IsNullOrEmpty(result.IndexId))
        {
            log( $"{result.IndexId}: delay={result.Delay}, speed={result.Speed}");
        }
        return Task.CompletedTask;
        }));
    }
    public void Started(SpeedTestAction action, IReadOnlyList<string> ids) => events.Publish("speedtest-started", new
    {
        code = "speedtest_started", messageKey = ApiMessageKeys.SpeedTestStarted,
        action = System.Text.Json.JsonNamingPolicy.CamelCase.ConvertName(action.ToString()), profileIds = ids,
    });
    public void Failed(Exception error) => log(error.Message);
    private sealed class Batch(List<ProfileItem> profiles, Func<SpeedtestService> create) : ISpeedTestBatch
    {
        private SpeedtestService? _service;
        public IReadOnlyList<string> ProfileIds { get; } = profiles.Select(item => item.IndexId).ToArray();
        public bool CanProbeSingle => profiles.Count == 1 && !profiles[0].IsComplex() && profiles[0].Port > 0;
        public bool SupportsXray => profiles.All(XrayOnlyPolicy.Supports);
        public Task RunAsync(SpeedTestAction action, CancellationToken token)
        {
            var service = create();
            Volatile.Write(ref _service, service);
            return service.RunLoop(action switch
            {
                SpeedTestAction.Tcping => ESpeedActionType.Tcping, SpeedTestAction.Realping => ESpeedActionType.Realping,
                SpeedTestAction.UdpTest => ESpeedActionType.UdpTest, SpeedTestAction.Speedtest => ESpeedActionType.Speedtest,
                SpeedTestAction.Mixedtest => ESpeedActionType.Mixedtest, _ => throw new ArgumentOutOfRangeException(nameof(action)),
            }, profiles, token);
        }
        public void Stop() => Volatile.Read(ref _service)?.ExitLoop();
    }
}
