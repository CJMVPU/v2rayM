using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using v2rayN.WebAPI.MacOS;

namespace v2rayN.WebAPI.Tests;

public class MacHelperContractTests
{
    private static string Fixture(string name, [CallerFilePath] string file = "") =>
        File.ReadAllText(Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, "../../../contracts/tun-helper", name)));

    [Test]
    public async Task SwiftResponseDecodesAndRoundTripsAllContractFields()
    {
        var json = Fixture("running-response.json");
        var response = JsonSerializer.Deserialize<MacHelperResponse>(json, MacTunCoreLauncher.JsonOptions)!;
        await response.ProtocolVersion.Should().BeEqualTo(MacHelperContract.Version);
        await response.VerifiedSHA256.Should().BeEqualTo("fixture-digest");
        await JsonNode.DeepEquals(JsonNode.Parse(json), JsonSerializer.SerializeToNode(response, MacTunCoreLauncher.JsonOptions)).Should().BeTrue();
    }
    [Test]
    public async Task CSharpRequestMatchesTheSwiftFixture()
    {
        var request = new { action = "start", core = "xray", config = "{\"inbounds\":[]}"u8.ToArray(),
            resources = new Dictionary<string, byte[]> { ["certificate.pem"] = "cert"u8.ToArray() },
            paths = new Dictionary<string, string> { ["/fixture/certificate.pem"] = "certificate.pem" }, configureSystemDNS = true };
        await JsonNode.DeepEquals(JsonNode.Parse(Fixture("start-request.json")),
            JsonSerializer.SerializeToNode(request, MacTunCoreLauncher.JsonOptions)).Should().BeTrue();
        await MacHelperContract.ResourceExtensions.Contains("srs").Should().BeFalse();
    }
    [Test]
    public async Task ProbeCoalescesObserversButCriticalActionsBypassCache()
    {
        var now = DateTimeOffset.UtcNow;
        var completion = new TaskCompletionSource<MacHelperResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var cache = new MacHelperProbe(() => { Interlocked.Increment(ref calls); return completion.Task; }, () => now);
        var observers = Enumerable.Range(0, 20).Select(_ => cache.ReadAsync()).ToArray();
        completion.SetResult(new(true, "ok", "idle", MacHelperContract.Version));
        await Task.WhenAll(observers);
        await calls.Should().BeEqualTo(1);
        await cache.ReadAsync(); await calls.Should().BeEqualTo(1);
        await cache.ReadAsync(fresh: true); await calls.Should().BeEqualTo(2);
        now = now.AddSeconds(31); await cache.ReadAsync(); await calls.Should().BeEqualTo(3);
        cache.Invalidate(); await cache.ReadAsync(); await calls.Should().BeEqualTo(4);
    }
    [Test]
    public async Task InvalidationDiscardsAnOldInFlightResultAndFailuresExpireQuickly()
    {
        var now = DateTimeOffset.UtcNow;
        var old = new TaskCompletionSource<MacHelperResponse>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var cache = new MacHelperProbe(() => Interlocked.Increment(ref calls) == 1 ? old.Task
            : Task.FromResult(new MacHelperResponse(false, "helper_unavailable", "unavailable")), () => now);
        var first = cache.ReadAsync();
        while (Volatile.Read(ref calls) == 0) await Task.Yield();
        cache.Invalidate();
        var current = await cache.ReadAsync();
        old.SetResult(new(true, "old", "idle", MacHelperContract.Version)); await first;
        await (await cache.ReadAsync()).Success.Should().BeFalse();
        await calls.Should().BeEqualTo(2);
        now = now.AddSeconds(3); await cache.ReadAsync(); await calls.Should().BeEqualTo(3);
    }
}
