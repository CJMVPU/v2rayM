using System.Diagnostics;
using System.Text.Json;
using ServiceLib.Services;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.MacOS;

/// <summary>The bridge owns the XPC lease; EOF or bridge death makes the helper stop its Core.</summary>
internal sealed class MacTunProcess : ProcessService
{
    private readonly Process _bridge;
    private readonly Action<string> _cleanupFailure;
    private readonly TaskCompletionSource<MacHelperResponse> _started = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Task _reader = Task.CompletedTask;
    private Task _errors = Task.CompletedTask;
    private bool _stopped;
    private bool _terminal;
    private int _pid;
    private CoreProcessIdentity? _identity;
    public override int Id => _pid;
    public override IntPtr Handle => IntPtr.Zero;
    public override bool HasExited { get { try { return _bridge.HasExited; } catch (InvalidOperationException) { return true; } } }
    public CoreProcessIdentity Identity => _identity!;

    private MacTunProcess(string path, Action<string> cleanupFailure)
    {
        _bridge = new Process { StartInfo = MacTunCoreLauncher.BridgeStartInfo(path, "run") };
        _cleanupFailure = cleanupFailure;
    }

    public static async Task<MacTunProcess> StartAsync(string path, string request, Func<bool, string, Task>? log, Action<string> cleanupFailure)
    {
        var service = new MacTunProcess(path, cleanupFailure);
        try
        {
            service._bridge.Start();
            service._errors = service._bridge.StandardError.ReadToEndAsync();
            service._reader = service.ReadMessagesAsync(log);
            await service._bridge.StandardInput.WriteLineAsync(request);
            await service._bridge.StandardInput.FlushAsync();
            var response = await service._started.Task.WaitAsync(TimeSpan.FromSeconds(25));
            service._pid = response.Pid!.Value;
            long start = 0;
            try { using var process = Process.GetProcessById(service.Id); start = process.StartTime.ToUniversalTime().Ticks; }
            catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { }
            service._identity = new(service.Id, Path.GetFileNameWithoutExtension(response.ExecutablePath!), start, response.ExecutablePath!);
            return service;
        }
        catch
        {
            try { service._bridge.StandardInput.Close(); } catch (InvalidOperationException) { }
            try { await service._bridge.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(25)); }
            catch (TimeoutException) { service._bridge.Kill(entireProcessTree: true); }
            service.Dispose();
            throw;
        }
    }

    private async Task ReadMessagesAsync(Func<bool, string, Task>? log)
    {
        try
        {
            while (await _bridge.StandardOutput.ReadLineAsync() is { } line)
            {
                if (line.Length > 8 * 1024 * 1024) throw new IOException("helper_response_too_large");
                var response = JsonSerializer.Deserialize<MacHelperResponse>(line, MacTunCoreLauncher.JsonOptions)
                    ?? throw new IOException("helper_protocol_invalid");
                if (response.ProtocolVersion != 2) throw new IOException("helper_protocol_mismatch");
                if (response.State == "running" && response.Success && response.Pid is > 1 && Path.IsPathRooted(response.ExecutablePath))
                    _started.TrySetResult(response);
                else if (!response.Success) _started.TrySetException(new IOException(response.Code));
                if (response.State is "stopped" or "faulted")
                {
                    _terminal = true;
                    _stopped = response.Success && !response.Forced && response.State == "stopped";
                }
                if (response.Forced) _cleanupFailure("forced_stop_cleanup_unconfirmed");
                foreach (var message in response.Logs ?? []) if (log is not null) await log(false, message);
            }
        }
        catch (Exception exception) when (exception is IOException or JsonException or InvalidOperationException)
        {
            _started.TrySetException(new IOException("helper_connection_failed", exception));
        }
        finally
        {
            _started.TrySetException(new IOException("helper_exited_before_start"));
            if (!_terminal && _pid > 0) _cleanupFailure("helper_connection_lost_cleanup_unconfirmed");
        }
    }

    public override async Task StopAsync()
    {
        try
        {
            if (!HasExited)
            {
                try { await _bridge.StandardInput.WriteLineAsync("stop"); _bridge.StandardInput.Close(); }
                catch (IOException) { }
                await _bridge.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(25));
            }
            await _reader;
            await _errors;
        }
        catch (Exception exception) when (exception is TimeoutException or IOException or InvalidOperationException)
        {
            _cleanupFailure("helper_stop_timeout_cleanup_unconfirmed");
            if (!HasExited) { _bridge.Kill(entireProcessTree: true); await _bridge.WaitForExitAsync(); }
        }
        // CoreManager must still stop an optional second Core. The host checks the
        // failure queue after both stop attempts and reports Faulted rather than Stopped.
        if (!_stopped) _cleanupFailure("helper_stop_cleanup_unconfirmed");
    }

    public override void Dispose() => _bridge.Dispose();
}
