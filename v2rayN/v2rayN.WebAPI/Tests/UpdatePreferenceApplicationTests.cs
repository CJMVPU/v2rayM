using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class UpdatePreferenceApplicationTests
{
    [Test]
    public async Task PendingRecoveryKeepsLaterSaveOutsideSnapshotAndWriteScope()
    {
        var store = new RecoveringStore();
        var service = new UpdatePreferenceService(store, new RuntimeMutationGate(), new(["Xray"], ["Xray"]));
        var first = service.SaveAsync(new(["Xray"], [], false, false));
        await store.RecoveryStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var second = service.SaveAsync(new(["GeoFiles"], [], false, true));
        try
        {
            await store.Captures.Should().BeEqualTo(1);
            await second.IsCompleted.Should().BeFalse();
        }
        finally { store.AllowRecovery.TrySetResult(); }
        var results = await Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(5));
        await results[0].Status.Should().BeEqualTo(UpdatePreferenceStatus.PersistenceFailed);
        await results[0].Restored.Should().BeTrue();
        await results[1].Status.Should().BeEqualTo(UpdatePreferenceStatus.Saved);
        await store.Value.SelectedTargets!.SequenceEqual(["HiddenPlatform", "GeoFiles"]).Should().BeTrue();
        await store.Value.UseProxy.Should().BeTrue();
        await store.Captures.Should().BeEqualTo(2);
    }

    [Test]
    public async Task DomainKeepsHiddenTargetsAndExplicitPreviewChoiceIndependentOfSelection()
    {
        var policy = new UpdatePreferencePolicy(["Xray", "Application"], ["Xray", "Application"]);
        var requested = policy.Validate(new(["GeoFiles", "GeoFiles"], ["Application"], false, false))!;
        var merged = policy.Merge(new(["Hidden", "Xray", "Hidden"], ["HiddenPreview", "Xray"], true), requested);
        await merged.SelectedTargets!.SequenceEqual(["Hidden", "GeoFiles"]).Should().BeTrue();
        await merged.PreReleaseTargets!.SequenceEqual(["HiddenPreview", "Application"]).Should().BeTrue();
        await merged.UseProxy.Should().BeFalse();
        await (policy.Validate(new([], ["GeoFiles"], false, true)) is null).Should().BeTrue();
        await (policy.Validate(new(["xray"], [], false, true)) is null).Should().BeTrue();
    }

    private sealed class RecoveringStore : IUpdatePreferenceStore
    {
        public UpdatePreferences Value = new(["HiddenPlatform"], [], true);
        public readonly TaskCompletionSource RecoveryStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource AllowRecovery = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int Captures;
        public Task<IUpdatePreferenceSession> CaptureAsync() => Task.FromResult<IUpdatePreferenceSession>(new Session(this, Value, ++Captures == 1));
        private sealed class Session(RecoveringStore store, UpdatePreferences snapshot, bool fail) : IUpdatePreferenceSession
        {
            public UpdatePreferences Current => store.Value;
            public Task SaveAsync(UpdatePreferences value)
            {
                store.Value = value;
                if (fail) throw new IOException("Partial write failed");
                return Task.CompletedTask;
            }
            public async Task RestoreAsync()
            {
                store.RecoveryStarted.TrySetResult();
                await store.AllowRecovery.Task;
                store.Value = snapshot;
            }
        }
    }
}
