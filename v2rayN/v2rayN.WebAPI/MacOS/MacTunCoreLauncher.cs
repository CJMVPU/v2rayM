using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ServiceLib.Base;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Models.CoreConfigs;
using ServiceLib.Services;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.MacOS;

internal sealed record MacHelperResponse(bool Success, string Code, string State, int ProtocolVersion = 0,
    int? Pid = null, string? ExecutablePath = null, string[]? Logs = null, bool Forced = false);

internal sealed class MacTunCoreLauncher(string? bridgePath) : IPrivilegedCoreLauncher
{
    internal static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly ConcurrentDictionary<int, MacTunProcess> _processes = new();
    private readonly ConcurrentQueue<string> _cleanupFailures = new();

    public static MacTunCoreLauncher ForCurrentApp()
    {
        if (!OperatingSystem.IsMacOS()) return new(null);
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !directory.Name.EndsWith(".app", StringComparison.Ordinal)) directory = directory.Parent;
        var bridge = directory is null ? null : Path.Combine(directory.FullName, "Contents", "MacOS", "V2rayMHelperClient");
        return new(bridge is not null && File.Exists(bridge) ? bridge : null);
    }

    public async Task<MacHelperResponse> ProbeAsync()
    {
        if (bridgePath is null) return new(false, "signed_app_bundle_required", "unavailable");
        using var process = new Process { StartInfo = BridgeStartInfo(bridgePath, "status") };
        try { process.Start(); }
        catch (System.ComponentModel.Win32Exception) { return new(false, "helper_client_unavailable", "unavailable"); }
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        try
        {
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            var line = (await output).Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
            var response = line is null ? null : JsonSerializer.Deserialize<MacHelperResponse>(line, JsonOptions);
            if (response is null || response.ProtocolVersion != 1) return new(false, "helper_protocol_mismatch", "unavailable");
            return response;
        }
        catch (Exception exception) when (exception is TimeoutException or JsonException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            return new(false, "helper_unavailable", "unavailable");
        }
        finally { await error; }
    }

    public async Task<ProcessService> StartAsync(CoreInfo coreInfo, string configPath, Func<bool, string, Task>? log)
    {
        if (bridgePath is null) throw new InvalidOperationException("signed_app_bundle_required");
        var kind = coreInfo.CoreType switch
        {
            ECoreType.sing_box => "sing_box",
            ECoreType.Xray => "xray",
            _ => throw new InvalidOperationException("mac_tun_core_not_supported"),
        };
        var request = BuildRequest(kind, configPath);
        var process = await MacTunProcess.StartAsync(bridgePath, request, log, failure => _cleanupFailures.Enqueue(failure));
        _processes[process.Id] = process;
        return process;
    }

    public CoreProcessIdentity[] CaptureIdentities() => _processes.Values
        .Where(process => !process.HasExited).Select(process => process.Identity).ToArray();

    public void ConfirmCleanup()
    {
        foreach (var entry in _processes.Where(entry => entry.Value.HasExited).ToArray()) _processes.TryRemove(entry.Key, out _);
        if (_cleanupFailures.TryPeek(out var failure)) throw new IOException(failure);
    }

    internal static ProcessStartInfo BridgeStartInfo(string path, string action)
    {
        var start = new ProcessStartInfo(path)
        {
            UseShellExecute = false, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true,
        };
        start.ArgumentList.Add(action);
        start.Environment.Remove("V2RAYN_WEB_API_KEY");
        return start;
    }

    internal static string BuildRequest(string kind, string configPath)
    {
        var bytes = File.ReadAllBytes(configPath);
        if (bytes.Length > 4 * 1024 * 1024) throw new IOException("mac_tun_config_too_large");
        var config = JsonNode.Parse(bytes) ?? throw new IOException("mac_tun_config_invalid");
        var resources = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        var paths = new Dictionary<string, string>(StringComparer.Ordinal);
        void AddFile(string original, string? fixedName = null)
        {
            if (paths.ContainsKey(original)) return;
            var file = Path.GetFullPath(original, Path.GetDirectoryName(configPath)!);
            var info = new FileInfo(file);
            if (!info.Exists || info.Length > 32 * 1024 * 1024) throw new IOException("mac_tun_resource_missing_or_too_large");
            var extension = Path.GetExtension(file).ToLowerInvariant();
            if (!new[] { ".dat", ".srs", ".pem", ".crt", ".key" }.Contains(extension)) throw new IOException("mac_tun_resource_type_not_supported");
            var name = fixedName ?? "resource_" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(file)))[..24] + extension;
            resources[name] = File.ReadAllBytes(file); paths[original] = name;
        }
        void Visit(JsonNode? node)
        {
            if (node is JsonArray array) { foreach (var item in array) Visit(item); return; }
            if (node is not JsonObject obj) return;
            foreach (var pair in obj)
            {
                if (pair.Key is "log" or "cache_file") continue;
                var key = pair.Key.Replace("_", "", StringComparison.Ordinal).ToLowerInvariant();
                var type = obj["type"]?.GetValue<string>();
                var isFile = new[] { "certificatepath", "keypath", "certificatefile", "keyfile", "cafile", "sslkeylog" }.Contains(key)
                    || pair.Key == "path" && type == "local";
                if (isFile && pair.Value is JsonValue value && value.TryGetValue<string>(out var path)) AddFile(path);
                else Visit(pair.Value);
            }
        }
        Visit(config);
        var text = Encoding.UTF8.GetString(bytes);
        if (kind == "xray")
        {
            foreach (var asset in new[] { "geoip", "geosite" })
            {
                if (!text.Contains(asset + ":", StringComparison.OrdinalIgnoreCase)) continue;
                var name = asset + ".dat";
                var path = new[] { Utils.GetBinPath(name), Utils.GetBinPath(name, "xray") }.FirstOrDefault(File.Exists)
                    ?? throw new IOException("mac_tun_geo_resource_missing");
                AddFile(path, name);
            }
        }
        if (resources.Count > 128 || resources.Values.Sum(value => (long)value.Length) > 64 * 1024 * 1024)
            throw new IOException("mac_tun_resources_too_large");
        return JsonSerializer.Serialize(new { action = "start", core = kind, config = bytes, resources, paths }, JsonOptions);
    }
}
