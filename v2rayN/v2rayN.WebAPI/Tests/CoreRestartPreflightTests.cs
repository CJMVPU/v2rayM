using V2rayM.Application.Runtime;
using V2rayM.Domain.Runtime;
using System.Net;
using System.Net.Sockets;
using ServiceLib.Enums;
using ServiceLib.Handler.Builder;
using ServiceLib.Models.CoreConfigs;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Contracts;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class CoreRestartPreflightTests
{
    [Test]
    public async Task RestartWithTunContextKeepsRunningCore()
    {
        var preflight = CoreLaunchPreflight.Validate(
            new ProfileItem(),
            CreateBuiltContext(isTunEnabled: true),
            _ => null);

        await AssertRestartRejectedWithoutStoppingCore(preflight, "tun_not_supported");
    }

    [Test]
    public async Task RestartWithInvalidContextKeepsRunningCore()
    {
        var binaryCheckCalled = false;
        var preflight = CoreLaunchPreflight.Validate(
            new ProfileItem(),
            CreateBuiltContext(valid: false),
            _ =>
            {
                binaryCheckCalled = true;
                return null;
            });

        await AssertRestartRejectedWithoutStoppingCore(preflight, "profile_validation_failed");
        await binaryCheckCalled.Should().BeFalse();
    }

    [Test]
    public async Task RestartWithMissingCoreBinaryKeepsRunningCore()
    {
        var preflight = CoreLaunchPreflight.Validate(
            new ProfileItem(),
            CreateBuiltContext(),
            coreType => OperationView.Fail("core_binary_missing", ApiMessageKeys.CoreBinaryMissing,
                new { coreType = coreType.ToString() }));

        await AssertRestartRejectedWithoutStoppingCore(preflight, "core_binary_missing");
    }

    [Test]
    public async Task ValidRestartStopsThenLaunchesThePreflightedContext()
    {
        var profile = new ProfileItem { IndexId = "profile-1" };
        var builtContext = CreateBuiltContext();
        var preflight = CoreLaunchPreflight.Validate(profile, builtContext, _ => null);
        var runtime = new CoreConnectionTestRuntime { Preflight = preflight };
        var result = await new CoreConnectionService(runtime).RestartAsync(default);
        var transitions = runtime.Calls.Where(call => call is "stop" or "launch").ToArray();
        await string.Join(",", transitions).Should().BeEqualTo("stop,launch");
        var launched = (CoreConnectionTestRuntime.TestPlan)runtime.LaunchedPlan!;
        await ReferenceEquals(launched.Preflight!.BuiltContext, builtContext).Should().BeTrue();
        await runtime.Current.State.Should().BeEqualTo(CoreRuntimeState.Running);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.Restarted);
    }

    [Test]
    public async Task UnrelatedListenerIsReportedUnavailableByTheNormalStartPreflightProbe()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        try
        {
            var target = new RuntimeListenerSnapshot("local", ["http", "socks"], "127.0.0.1", port);

            // With no Core owned by Web, the probe must reject the port before launch.
            var unavailableForUnrelatedOwner = await V2rayRuntime.IsProjectedListenerUnavailableAsync(
                target,
                runtimeOwned: [],
                CancellationToken.None);
            await unavailableForUnrelatedOwner.Should().BeTrue();

            // The same listener is fine while Web still owns the tracked Core process.
            var unavailableForOwnedListener = await V2rayRuntime.IsProjectedListenerUnavailableAsync(
                target,
                runtimeOwned: [target],
                CancellationToken.None);
            await unavailableForOwnedListener.Should().BeFalse();
        }
        finally
        {
            listener.Stop();
        }
    }

    private static async Task AssertRestartRejectedWithoutStoppingCore(
        CoreLaunchPreflightResult preflight,
        string expectedCode)
    {
        var runtime = new CoreConnectionTestRuntime { Preflight = preflight };
        var previous = runtime.Current;
        var result = await new CoreConnectionService(runtime).RestartAsync(default);
        await result.Status.Should().BeEqualTo(CoreConnectionStatus.PreflightRejected);
        await preflight.Failure!.Code.Should().BeEqualTo(expectedCode);
        await runtime.Calls.Contains("stop").Should().BeFalse();
        await runtime.Calls.Contains("launch").Should().BeFalse();
        await runtime.Current.Should().BeEqualTo(previous);
    }

    private static CoreConfigContextBuilderAllResult CreateBuiltContext(
        bool isTunEnabled = false,
        bool valid = true)
    {
        var validator = valid
            ? NodeValidatorResult.Empty()
            : new NodeValidatorResult(["invalid"], []);
        return new CoreConfigContextBuilderAllResult(
            new CoreConfigContextBuilderResult(
                new CoreConfigContext
                {
                    Node = new ProfileItem(),
                    RunCoreType = ECoreType.Xray,
                    IsTunEnabled = isTunEnabled,
                },
                validator),
            null);
    }
}
