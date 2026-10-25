using v2rayN.WebAPI.MacOS;

namespace v2rayN.WebAPI.Tests;

public class MacTunCleanupRecoveryTests
{
    [Test]
    public async Task MissingStartAcknowledgementRetainsOriginalLeaseUntilHelperConfirmsCleanup()
    {
        if (OperatingSystem.IsWindows()) return;
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-start-lost-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var bridge = Path.Combine(directory, "bridge.sh");
            await File.WriteAllTextAsync(bridge, """
                #!/bin/sh
                IFS= read -r request
                # Helper may have accepted the request; its PID reply was lost.
                exit 0
                """);
            File.SetUnixFileMode(bridge, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var token = Guid.NewGuid().ToString();
            var receipt = new MacHelperResponse(false, "session_cleanup_unknown", "unavailable", MacHelperContract.Version);
            var queried = 0;
            var launcher = new MacTunCoreLauncher(null, received =>
            {
                if (received != token) throw new Exception("Wrong session token");
                queried++;
                return Task.FromResult(receipt);
            });
            var reported = new List<string>();
            var startFailed = false;
            try
            {
                using var unexpected = await MacTunProcess.StartAsync(bridge, "{}", null, failure =>
                {
                    reported.Add(failure); launcher.RecordCleanupFailure(token, failure);
                });
            }
            catch (IOException) { startFailed = true; }
            await startFailed.Should().BeTrue();
            await reported.Contains("helper_start_cleanup_unconfirmed").Should().BeTrue();
            var rejected = false;
            try { await launcher.ConfirmCleanupAsync(CancellationToken.None); }
            catch (IOException) { rejected = true; }
            await rejected.Should().BeTrue();
            await queried.Should().BeEqualTo(1);
            receipt = new(true, "session_cleanup_confirmed", "stopped", MacHelperContract.Version);
            await launcher.ConfirmCleanupAsync(CancellationToken.None);
            await queried.Should().BeEqualTo(2);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Test]
    public async Task LostBridgeReconcilesThroughANewBridgeUsingTheOriginalToken()
    {
        if (OperatingSystem.IsWindows()) return;
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-lost-bridge-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var token = Guid.NewGuid().ToString();
            var bridge = Path.Combine(directory, "bridge.sh");
            await File.WriteAllTextAsync(bridge, """
                #!/bin/sh
                IFS= read -r input
                if [ "$1" = "cleanup-status" ]; then
                    [ "$input" = "__TOKEN__" ] || exit 2
                    printf '{"success":true,"code":"session_cleanup_confirmed","state":"stopped","protocolVersion":__VERSION__}\n'
                else
                    printf '{"success":true,"code":"ok","state":"running","protocolVersion":__VERSION__,"pid":%s,"executablePath":"/bin/sh"}\n' "$$"
                    IFS= read -r stop
                    # Simulate EOF without a terminal acknowledgement.
                fi
                """.Replace("__TOKEN__", token).Replace("__VERSION__", MacHelperContract.Version.ToString()));
            File.SetUnixFileMode(bridge, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var launcher = new MacTunCoreLauncher(bridge);
            var failures = new List<string>();
            using var process = await MacTunProcess.StartAsync(bridge, "{}", null, failure =>
            {
                failures.Add(failure); launcher.RecordCleanupFailure(token, failure);
            });
            await process.StopAsync();
            await failures.Contains("helper_connection_lost_cleanup_unconfirmed").Should().BeTrue();
            await launcher.ConfirmCleanupAsync(CancellationToken.None);
            await launcher.ConfirmCleanupAsync(CancellationToken.None);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Test]
    public async Task LostLeaseRetriesPendingCleanupThenAllowsRepeatedStopAndRecovery()
    {
        var token = Guid.NewGuid().ToString();
        var calls = 0;
        var launcher = new MacTunCoreLauncher(null, received =>
        {
            if (received != token) throw new Exception("Wrong session");
            return Task.FromResult(++calls == 1
                ? new MacHelperResponse(false, "session_cleanup_pending", "stopping", MacHelperContract.Version)
                : new MacHelperResponse(true, "session_cleanup_confirmed", "stopped", MacHelperContract.Version));
        });
        launcher.RecordCleanupFailure(token, "helper_connection_lost_cleanup_unconfirmed");
        await launcher.ConfirmCleanupAsync(CancellationToken.None);
        await launcher.ConfirmCleanupAsync(CancellationToken.None);
        await calls.Should().BeEqualTo(2);
    }

    [Test]
    public async Task HealthyNewSessionForcedStopAndWrongProtocolCannotClearLostLease()
    {
        foreach (var response in new MacHelperResponse[] {
            new(true, "ok", "idle", MacHelperContract.Version),
            new(false, "session_cleanup_unknown", "unavailable", MacHelperContract.Version),
            new(false, "session_cleanup_unconfirmed", "faulted", MacHelperContract.Version),
            new(true, "session_cleanup_confirmed", "stopped", MacHelperContract.Version, Forced: true),
            new(true, "session_cleanup_confirmed", "stopped", MacHelperContract.Version - 1) })
        {
            var observed = response;
            var calls = 0;
            var launcher = new MacTunCoreLauncher(null, _ => { calls++; return Task.FromResult(observed); });
            launcher.RecordCleanupFailure(Guid.NewGuid().ToString(), "lost");
            for (var i = 0; i < 2; i++)
            {
                var rejected = false;
                try { await launcher.ConfirmCleanupAsync(CancellationToken.None); }
                catch (IOException) { rejected = true; }
                await rejected.Should().BeTrue();
            }
            observed = new(true, "session_cleanup_confirmed", "stopped", MacHelperContract.Version);
            await launcher.ConfirmCleanupAsync(CancellationToken.None);
            await calls.Should().BeEqualTo(3);
        }
    }

    [Test]
    public async Task CancellationRetainsUnconfirmedLeaseForNextStop()
    {
        using var cancellation = new CancellationTokenSource();
        var confirmed = false;
        var launcher = new MacTunCoreLauncher(null, _ =>
        {
            if (!confirmed) cancellation.Cancel();
            return Task.FromResult(confirmed
                ? new MacHelperResponse(true, "session_cleanup_confirmed", "stopped", MacHelperContract.Version)
                : new MacHelperResponse(false, "session_cleanup_pending", "stopping", MacHelperContract.Version));
        });
        launcher.RecordCleanupFailure(Guid.NewGuid().ToString(), "lost");
        var cancelled = false;
        try { await launcher.ConfirmCleanupAsync(cancellation.Token); }
        catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        confirmed = true;
        await launcher.ConfirmCleanupAsync(CancellationToken.None);
    }
}
