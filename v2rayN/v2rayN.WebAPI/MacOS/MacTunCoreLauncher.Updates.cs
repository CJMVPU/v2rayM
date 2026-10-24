using System.Diagnostics;
using System.Text.Json;
using ServiceLib.Enums;

namespace v2rayN.WebAPI.MacOS;

internal sealed partial class MacTunCoreLauncher
{
    internal bool SupportsTrustedUpdate(ECoreType coreType) => bridgePath is not null && coreType is ECoreType.Xray;

    internal async Task<string?> StageUpdateAsync(ECoreType coreType, string archivePath, string releaseURL, CancellationToken cancellationToken)
    {
        if (bridgePath is null || coreType is not ECoreType.Xray) return null;
        var probe = await ProbeAsync();
        if (!probe.Success) throw new IOException("请先在 TUN 设置中授权后台服务，再更新特权内核。");
        var file = new FileInfo(archivePath);
        if (!file.Exists || file.Length > 64L * 1024 * 1024) throw new IOException("The privileged update package exceeds its size limit.");
        var response = await UpdateAsync(new { action = "update-stage", core = Kind(coreType), releaseURL,
            archive = await File.ReadAllBytesAsync(archivePath, cancellationToken) }, cancellationToken);
        return response.UpdateToken ?? throw new IOException("The helper did not return an update token.");
    }

    internal async Task TransitionUpdateAsync(ECoreType coreType, string? token, string action, CancellationToken cancellationToken)
    {
        if (token is null) return;
        await UpdateAsync(new { action, core = Kind(coreType), updateToken = token }, cancellationToken);
    }

    private static string Kind(ECoreType coreType) => coreType == ECoreType.Xray ? "xray" : throw new InvalidOperationException("mac_tun_core_not_supported");

    private async Task<MacHelperResponse> UpdateAsync<T>(T request, CancellationToken cancellationToken)
    {
        if (bridgePath is null) throw new IOException("A signed app is required for privileged updates.");
        using var process = new Process { StartInfo = BridgeStartInfo(bridgePath, "update") };
        process.Start();
        var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var error = process.StandardError.ReadToEndAsync(cancellationToken);
        try
        {
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(request, JsonOptions).AsMemory(), cancellationToken);
            process.StandardInput.Close();
            await process.WaitForExitAsync(cancellationToken).WaitAsync(TimeSpan.FromSeconds(125), cancellationToken);
            var line = (await output).Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
            var response = line is null ? null : JsonSerializer.Deserialize<MacHelperResponse>(line, JsonOptions);
            if (response is not null && response.ProtocolVersion != MacHelperContract.Version)
                throw new IOException("TUN 后台服务协议版本不匹配，请更新后台服务后重试。");
            if (process.ExitCode != 0 || response is null || !response.Success)
                throw new IOException("TUN 安全更新未完成：" + (response?.Code ?? "helper_update_failed"));
            return response;
        }
        finally
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(CancellationToken.None);
            try { await error; } catch (OperationCanceledException) { }
        }
    }
}
