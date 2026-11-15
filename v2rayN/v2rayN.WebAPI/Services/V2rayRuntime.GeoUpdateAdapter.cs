using V2rayM.Application.Updates;
using V2rayM.Domain.Runtime;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private sealed class GeoUpdateRunAdapter(V2rayRuntime owner, bool useProxy, string scope) : IGeoUpdateRun
    {
        public bool IsStopping => owner._operations.IsStopping;
        public bool WasRunning => owner.CurrentCoreRuntime.State == CoreRuntimeState.Running;
        public async ValueTask<IUpdateOperationLease> EnterAsync() => await owner._operations.EnterExclusiveAsync(
            owner._operations.ShutdownToken, allowReadOnlyObservations: true);
        public Task ApplyFilesAsync(Func<Func<Task>, CancellationToken, Task>? beforeCommit, CancellationToken token) =>
            owner.ApplyGeoFilesUpdateAsync(useProxy, token, scope: scope, beforeCommit: beforeCommit);
        public async Task<bool> RestartAsync(CancellationToken token) => (await owner.RestartCoreAsync(token)).Success;
        public void Publish(GeoUpdatePhase phase, string? detail = null) => owner.PublishGeoUpdateProgress(phase switch
        {
            GeoUpdatePhase.Downloading => "downloading", GeoUpdatePhase.Restarting => "restarting-core",
            GeoUpdatePhase.RollingBack => "rolling-back", GeoUpdatePhase.Completed => "completed", _ => "failed",
        }, phase is GeoUpdatePhase.Completed or GeoUpdatePhase.Failed, phase == GeoUpdatePhase.Completed, detail);
        public void Log(string message) => owner.AddLog("update", message);
    }
}
