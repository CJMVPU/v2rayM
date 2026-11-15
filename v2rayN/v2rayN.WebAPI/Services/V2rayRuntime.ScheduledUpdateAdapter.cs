using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Dto;
using ServiceLib.Resx;
using ServiceLib.Services;
using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private sealed class ScheduledUpdateCheckAdapter(V2rayRuntime owner) : IScheduledUpdateCheck
    {
        // Single-target release checks use no mutable runtime configuration.
        private readonly UpdateService checker = new(new Config(), (_, _) => Task.CompletedTask);
        public async Task<ScheduledUpdatePlan> CaptureAsync(CancellationToken token)
        {
            await using var lease = await owner._operations.EnterOperationAsync(token);
            return await owner._mutations.RunAsync(() => CaptureLockedAsync(lease.Token), lease.Token);
        }
        private async Task<ScheduledUpdatePlan> CaptureLockedAsync(CancellationToken token)
        {
            var preferences = owner.Config.CheckUpdateItem;
            var targets = new List<ScheduledUpdateTarget>();
            foreach (var type in CoreInfoManager.Instance.GetCheckUpdateCoreTypes())
            {
                if (!(preferences.SelectedCoreTypes?.Contains(type.ToString()) ?? true)) continue;
                token.ThrowIfCancellationRequested();
                var version = await checker.GetInstalledVersionAsync(type, token);
                token.ThrowIfCancellationRequested();
                targets.Add(new(type.ToString(), preferences.CheckPreReleaseCoreTypes?.Contains(type.ToString()) ?? false,
                    version.ToStandardVersionString()));
            }
            return new(preferences.UpdateViaProxy, targets.ToArray(), AppManager.Instance.GetLocalPort(EInboundProtocol.socks));
        }
        public async Task<ScheduledUpdateResult> CheckRemoteAsync(ScheduledUpdateTarget target, bool useProxy, int proxyPort, CancellationToken token)
        {
            var type = Enum.Parse<ECoreType>(target.Id);
            var result = await checker.CheckHasUpdateOnly(type, target.PreRelease, useProxy, token,
                installedVersion: new SemanticVersion(target.InstalledVersion), localProxyPort: proxyPort);
            token.ThrowIfCancellationRequested();
            var available = result.Success && result.Version is not null;
            return new(target.Id, available, available ? string.Format(ResUI.MsgCheckUpdateHasNewVersion, type, result.Version) : result.Msg);
        }
        public async Task<bool> TryPublishAsync(ScheduledUpdatePlan captured, IReadOnlyList<ScheduledUpdateResult> results, CancellationToken token)
        {
            await using var lease = await owner._operations.EnterOperationAsync(token);
            return await owner._mutations.RunAsync(async () =>
            {
                var current = await CaptureLockedAsync(lease.Token);
                if (!captured.Matches(current)) return false;
                lease.Token.ThrowIfCancellationRequested();
                foreach (var result in results)
                {
                    AppManager.Instance.SetLastCheckUpdateResult(Enum.Parse<ECoreType>(result.Target), result.Detail ?? string.Empty);
                    if (result.Available) owner.AddLog("update", result.Detail ?? string.Empty);
                }
                return true;
            }, lease.Token);
        }
        public void Log(string message) => owner.AddLog("update", message);
    }
}
