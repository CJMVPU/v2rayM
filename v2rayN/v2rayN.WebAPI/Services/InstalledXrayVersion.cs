using System.Text.RegularExpressions;
using ServiceLib.Common;

namespace v2rayN.WebAPI.Services;

internal sealed record XrayBuildIdentity(string UpstreamVersion, string? RepairId)
{
    public string DisplayVersion => UpstreamVersion + (RepairId switch { "darwin-bind1" => "（修复版 M1）", "darwin-bind2" => "（修复版 M2）", _ => "" });
}

// Only probes the executable already selected by the runtime. Cache by file identity
// so dashboard polling does not spawn a process each second, and updates invalidate it.
internal sealed class InstalledXrayVersion(Func<string, CancellationToken, Task<string?>>? probe = null)
{
    private readonly Func<string, CancellationToken, Task<string?>> _probe = probe ?? ((path, token) => Utils.GetCliWrapOutput(path, "version", token));
    private readonly SemaphoreSlim _gate = new(1, 1);
    private (string Path, long Size, DateTime Written)? _identity;
    private XrayBuildIdentity? _version;
    private DateTime _retryAfter;

    internal static string? Parse(string? output) => ParseIdentity(output)?.DisplayVersion;

    internal static XrayBuildIdentity? ParseIdentity(string? output)
    {
        var match = Regex.Match(output ?? "", @"\AXray\s+(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)(?:\s|$)");
        return match.Success ? new(match.Groups[1].Value,
            ParseRepairId(output!)) : null;
    }

    internal static string? ParseRepairId(string output)
    {
        var repair = Regex.Match(output, @"(?:^|\s)\S*-v2raym-(darwin-bind[12])(?:\s|$)");
        return repair.Success ? repair.Groups[1].Value : null;
    }

    public async Task<string?> ReadAsync(string? path) => (await ReadIdentityAsync(path))?.DisplayVersion;

    internal async Task<XrayBuildIdentity?> ReadIdentityAsync(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
        await _gate.WaitAsync();
        try
        {
            var file = new FileInfo(path);
            var identity = (path, file.Length, file.LastWriteTimeUtc);
            if (_identity == identity && (_version != null || DateTime.UtcNow < _retryAfter)) return _version;
            _identity = identity;
            _version = null;
            _retryAfter = DateTime.UtcNow.AddSeconds(30);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            _version = ParseIdentity(await _probe(path, timeout.Token));
            return _version;
        }
        catch { return null; }
        finally { _gate.Release(); }
    }
}
