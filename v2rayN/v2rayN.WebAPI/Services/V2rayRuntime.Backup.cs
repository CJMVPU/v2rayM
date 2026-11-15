using V2rayM.Application.Backups;
using V2rayM.Application.Settings;
using V2rayM.Domain.Backups;
using v2rayN.WebAPI.Adapters.Settings;
using V2rayM.Domain.Runtime;
using System.IO.Compression;
using System.Text.Json;
using SQLite;
using ServiceLib;
using ServiceLib.Common;
using ServiceLib.Handler;
using ServiceLib.Helper;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using v2rayN.WebAPI.Contracts;
using v2rayN.WebAPI.Launcher;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    private readonly object _restoreShutdownGate = new();
    private Task? _restoreShutdownTask;
    private const long MaxBackupArchiveBytes = BackupPolicy.MaximumArchiveBytes;
    private const long MaxBackupExpandedBytes = BackupPolicy.MaximumExpandedBytes;
    private const int MaxBackupEntries = BackupPolicy.MaximumEntries;
    internal const string WebAuthFileName = "WebAPI-auth.json";
    private const string RestoreRuntimeStateFileName = "v2rayn-WebAPI-restore-state.json";
    private NativeWebRestoreReplacement? _nativeRestoreReplacement;

    public NativeWebRestoreReplacement? NativeRestoreReplacement => _nativeRestoreReplacement;

    public WebDavSettingsView GetWebDavSettings() => new(
        Config.WebDavItem.Url,
        Config.WebDavItem.UserName,
        Config.WebDavItem.DirName,
        !string.IsNullOrEmpty(Config.WebDavItem.Password));

    public async Task<OperationView> UpdateWebDavSettingsAsync(WebDavSettingsInput input)
    {
        var result = await _settingsEditor.EditAsync(new(WebDav: new(input.Url, input.UserName, input.Password, input.DirName)));
        return result.Status == SettingsEditStatus.Saved
            ? OperationView.Ok(ApiMessageKeys.WebDavSettingsSaved)
            : SettingsContractMapper.Failure(result, "webdav");
    }

    public async Task<OperationView> CheckWebDavAsync()
    {
        var success = await RunWebDavTransferAsync(async () =>
        {
            var connected = await WebDavManager.Instance.CheckConnection();
            if (!connected) AddLog("backup", WebDavManager.Instance.GetLastError());
            return connected;
        }, _operations.ShutdownToken);
        return success
            ? OperationView.Ok(ApiMessageKeys.WebDavCheckSucceeded)
            : OperationView.Fail("webdav_check_failed", ApiMessageKeys.WebDavCheckFailed);
    }

    public async Task<(OperationView Result, string? FilePath)> CreateBackupArchiveAsync()
    {
        var result = await CreateBackupArtifactAsync();
        return result.Status switch
        {
            BackupArchiveStatus.Created when result.Artifact is BackupArtifact artifact =>
                (OperationView.Ok(ApiMessageKeys.BackupCreated, new { fileName = artifact.Name }), artifact.Path),
            BackupArchiveStatus.TooLarge => (OperationView.Fail("backup_archive_too_large", ApiMessageKeys.BackupArchiveInvalid), null),
            _ => (OperationView.Fail("backup_create_failed", ApiMessageKeys.BackupArchiveInvalid), null),
        };
    }

    private Task<BackupArchiveResult> CreateBackupArtifactAsync() =>
        new BackupArchiveService(_mutations).CreateAsync(new BackupArchiveSession(this));

    public async Task<OperationView> BackupToWebDavAsync()
    {
        var result = await new BackupUploadService(new BackupUploadAdapter(this)).UploadAsync();
        return result.Status switch
        {
            BackupUploadStatus.Uploaded => OperationView.Ok(ApiMessageKeys.WebDavBackupSucceeded, new { fileName = result.FileName }),
            BackupUploadStatus.CreationFailed => OperationView.Fail(
                result.CreationStatus == BackupArchiveStatus.TooLarge ? "backup_archive_too_large" : "backup_create_failed", ApiMessageKeys.BackupArchiveInvalid),
            _ => OperationView.Fail("webdav_backup_failed", ApiMessageKeys.WebDavCheckFailed),
        };
    }

    public async Task<OperationView> RestoreFromWebDavAsync(CancellationToken cancellationToken)
    {
        var path = Utils.GetTempPath($"restore_{Utils.GetGuid(false)}.zip");
        if (!await new RestoreInputService(new RestoreInput(this, path)).PrepareAsync(cancellationToken))
            return OperationView.Fail("webdav_restore_download_failed", ApiMessageKeys.WebDavRestoreFailed);
        return await RestoreBackupArchiveAsync(path, cancellationToken);
    }

    public async Task<OperationView> RestoreFromUploadAsync(Stream archive, CancellationToken cancellationToken)
    {
        var path = Utils.GetTempPath($"restore_{Utils.GetGuid(false)}.zip");
        await new RestoreInputService(new RestoreInput(this, path, archive)).PrepareAsync(cancellationToken);
        return await RestoreBackupArchiveAsync(path, cancellationToken);
    }

    private async Task<OperationView> RestoreBackupArchiveAsync(string archivePath, CancellationToken cancellationToken)
    {
        var session = new BackupRestoreSession(this, archivePath);
        var result = await new BackupRestoreService(session).RestoreAsync(cancellationToken);
        return result.Status switch
        {
            BackupRestoreStatus.Started => OperationView.Ok(ApiMessageKeys.BackupRestoreStarted,
                new { restartRequired = true, safetyBackup = result.SafetyBackup }),
            BackupRestoreStatus.InvalidArchive => OperationView.Fail("backup_archive_invalid", ApiMessageKeys.BackupArchiveInvalid),
            BackupRestoreStatus.IncompatibleDatabase => OperationView.Fail("backup_database_incompatible", ApiMessageKeys.BackupDatabaseIncompatible),
            BackupRestoreStatus.PreflightRejected => session.PreflightFailure(),
            BackupRestoreStatus.SafetyBackupFailed => OperationView.Fail("backup_safety_copy_failed", ApiMessageKeys.BackupRestoreFailed),
            _ => OperationView.Fail("backup_restore_failed", ApiMessageKeys.BackupRestoreFailed),
        };
    }

    private NativeWebRestorePreflightResult EvaluateNativeRestorePreflight()
    {
        var processPath = Environment.ProcessPath;
        var processArguments = Environment.GetCommandLineArgs();
        return NativeWebRestorePreflight.Evaluate(
            _configuration,
            isLinux: OperatingSystem.IsLinux(),
            isWindows: OperatingSystem.IsWindows(),
            externalSupervisor: LauncherEnvironment.IsSystemdManagedDeployment(),
            containerEnvironment: LauncherEnvironment.IsCurrentContainerEnvironment(),
            setsidPath: OperatingSystem.IsLinux() ? LinuxXdgBrowserOpener.FindExecutable("setsid") : null,
            processPath: processPath,
            managedEntryPoint: WebReplacementCommand.GetManagedEntryPoint(processPath, processArguments),
            hostArguments: GetCurrentHostArguments(),
            coreWasRunning: CurrentCoreRuntime.State == CoreRuntimeState.Running);
    }

    // Restore failed before database replacement: bring the pre-restore Core runtime intent
    // back. Only Web-captured Core process identities prove that the previous Core still
    // exists; listener or port occupancy is never used as process ownership. When no tracked
    // process remains, the normal start path attempts the restart and its launch preflight
    // reports a port conflict (proxy_port_in_use) if another program now owns the port.
    internal static async Task<OperationView?> RecoverRuntimeAfterFailedRestoreAsync(
        RuntimeRestartIntent restoreState,
        int[] remainingCoreProcessIds,
        Action<int[], string> markRuntimeFaulted,
        Func<string?, CancellationToken, Task<OperationView>> startCore,
        Action<string> log,
        CancellationToken cancellationToken)
    {
        OperationView? operation = null;
        await FailedRestoreRecovery.RecoverAsync(restoreState, remainingCoreProcessIds, markRuntimeFaulted,
            async (id, token) =>
            {
                operation = await startCore(id, token);
                return new V2rayM.Application.Runtime.RuntimeStartResult(operation.Success, operation.Code);
            }, log);
        return operation;
    }

    private void TryDeleteRestoreDirectory(string path, string description)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (Exception exception)
        {
            AddLog("backup", $"Restore {description} cleanup failed: {exception.Message}");
        }
    }

    private void RequestHostShutdownForRestore()
    {
        Interlocked.Exchange(ref _restoreAndRestartRequested, 1);
        lock (_restoreShutdownGate)
        {
            if (_restoreShutdownTask is { IsCompleted: false })
            {
                return;
            }
            var stoppingToken = _lifetime.ApplicationStopping;
            _restoreShutdownTask = Task.Run(async () =>
            {
                try
                {
                    // Give the restore API response time to flush; process handoff below
                    // waits for the actual instance lock, never for this delay.
                    await Task.Delay(TimeSpan.FromSeconds(1), stoppingToken);
                    if (!stoppingToken.IsCancellationRequested)
                    {
                        _lifetime.StopApplication();
                    }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    // The host is already stopping.
                }
            });
        }
    }

    private static string RestoreRuntimeStatePath => Path.Combine(Utils.StartupPath(), RestoreRuntimeStateFileName);
    internal static string WebUpdateRuntimeStatePath => Utils.GetTempPath("WebAPI-update-runtime-state.json");

    private static async Task WriteRestoreRuntimeStateAsync(RuntimeRestartIntent state)
    {
        await WriteRuntimeIntentAsync(RestoreRuntimeStatePath, state);
    }

    internal static async Task WriteRuntimeIntentAsync(string path, RuntimeRestartIntent state)
    {
        var temporary = path + $".{Guid.NewGuid():N}.tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(state));
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static Task<RuntimeRestartIntent?> LoadRestoreRuntimeStateAsync(CancellationToken cancellationToken) =>
        LoadRuntimeRestartIntentAsync(RestoreRuntimeStatePath, cancellationToken);

    internal static async Task<RuntimeRestartIntent?> LoadRuntimeRestartIntentAsync(string path, CancellationToken cancellationToken)
    {
        RequeueAbandonedRestoreRuntimeClaim(path);
        try
        {
            if (!File.Exists(path)) return null;
            var json = await File.ReadAllTextAsync(path, cancellationToken);
            return JsonSerializer.Deserialize<RuntimeRestartIntent>(json);
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }
        catch (Exception exception) when (exception is IOException or JsonException)
        {
            Logging.SaveLog("Restore runtime-state marker could not be read: " + exception.Message);
            return null;
        }
    }

    internal static Task CommitRestoreRuntimeStateAsync() => CommitRestoreRuntimeStateAsync(RestoreRuntimeStatePath);

    internal static Task CommitRestoreRuntimeStateAsync(string path)
    {
        try
        {
            // Keep the primary marker until every abandoned claim has been removed. If
            // cleanup fails or the process crashes here, startup still has a recoverable
            // authoritative marker and can retry cleanup.
            DeleteRestoreRuntimeClaims(path, requireComplete: true);
            if (File.Exists(path)) File.Delete(path);
            if (File.Exists(path))
            {
                throw new IOException("The committed restore runtime-state marker still exists.");
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            Logging.SaveLog("Committed restore runtime-state marker could not be removed: " + exception.Message);
            return Task.FromException(exception);
        }
        return Task.CompletedTask;
    }

    private static void RequeueAbandonedRestoreRuntimeClaim(string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory)) return;
        try
        {
            var pattern = Path.GetFileName(path) + ".consuming-*";
            var claims = Directory.EnumerateFiles(directory, pattern, SearchOption.TopDirectoryOnly)
                .OrderBy(claim => claim, StringComparer.Ordinal)
                .Select(ReadRestoreRuntimeClaim)
                .ToArray();

            // A valid primary marker is authoritative when an interrupted consume left
            // duplicate claims behind. An invalid primary must not hide the only valid
            // recoverable claim.
            if (TryReadRestoreRuntimeIntent(path) is not null)
            {
                DeleteRestoreRuntimeClaims(path);
                return;
            }

            // A consuming claim is a renamed copy of the marker. Prefer the most recently
            // written valid intent; ties prefer the more informative running/profile state,
            // then the ordinal filename. Never rely on directory enumeration order.
            var selected = claims
                .Where(claim => claim.Intent is not null)
                .OrderByDescending(claim => claim.LastWriteTimeUtc)
                .ThenByDescending(claim => claim.Intent!.WasRunning)
                .ThenByDescending(claim => !string.IsNullOrWhiteSpace(claim.Intent!.PreferredProfileId))
                .ThenBy(claim => claim.Path, StringComparer.Ordinal)
                .FirstOrDefault();

            if (selected is not null)
            {
                try
                {
                    File.Move(selected.Path, path, overwrite: true);
                    Logging.SaveLog("Recovered the newest valid interrupted restore runtime-state marker claim.");
                    DeleteRestoreRuntimeClaims(path);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    if (TryReadRestoreRuntimeIntent(path) is not null)
                    {
                        // Another writer restored a valid primary marker; it is authoritative.
                        DeleteRestoreRuntimeClaims(path);
                        return;
                    }

                    // Keep all claims when replacement failed: one of them may be the only
                    // valid copy needed by a later startup.
                    Logging.SaveLog("Abandoned restore runtime-state claim could not be moved to the primary marker: " + exception.Message);
                    return;
                }

                return;
            }

            DeleteRestoreRuntimeClaims(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            Logging.SaveLog("Abandoned restore runtime-state claim could not be recovered: " + exception.Message);
        }
    }

    private static RuntimeRestartIntent? TryReadRestoreRuntimeIntent(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<RuntimeRestartIntent>(File.ReadAllText(path));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    private static RestoreRuntimeClaim ReadRestoreRuntimeClaim(string claimPath)
    {
        RuntimeRestartIntent? intent = null;
        try
        {
            intent = JsonSerializer.Deserialize<RuntimeRestartIntent>(File.ReadAllText(claimPath));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            Logging.SaveLog($"Ignoring invalid abandoned restore runtime-state claim {Path.GetFileName(claimPath)}: {exception.Message}");
        }

        DateTime lastWriteTimeUtc;
        try { lastWriteTimeUtc = File.GetLastWriteTimeUtc(claimPath); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            lastWriteTimeUtc = DateTime.MinValue;
        }
        return new RestoreRuntimeClaim(claimPath, intent, lastWriteTimeUtc);
    }

    private static void DeleteRestoreRuntimeClaims(string path, bool requireComplete = false)
    {
        var directory = Path.GetDirectoryName(path);
        if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory)) return;
        try
        {
            var pattern = Path.GetFileName(path) + ".consuming-*";
            foreach (var claim in Directory.EnumerateFiles(directory, pattern, SearchOption.TopDirectoryOnly))
            {
                try
                {
                    File.Delete(claim);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    if (requireComplete) throw;
                    Logging.SaveLog("Committed abandoned restore runtime-state claim could not be removed: " + exception.Message);
                }
            }
            if (requireComplete && Directory.EnumerateFiles(directory, pattern, SearchOption.TopDirectoryOnly).Any())
            {
                throw new IOException("One or more abandoned restore runtime-state claims still exist.");
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            if (requireComplete) throw;
            Logging.SaveLog("Committed abandoned restore runtime-state claims could not be removed: " + exception.Message);
        }
    }

    private sealed record RestoreRuntimeClaim(string Path, RuntimeRestartIntent? Intent, DateTime LastWriteTimeUtc);

    internal static Task DeleteRuntimeIntentAsync(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            Logging.SaveLog("Runtime restart intent could not be removed: " + exception.Message);
        }
        return Task.CompletedTask;
    }

    private async Task WaitForRestoreShutdownRequestAsync(CancellationToken cancellationToken)
    {
        Task? restartTask;
        lock (_restoreShutdownGate)
        {
            restartTask = _restoreShutdownTask;
        }
        if (restartTask is not null)
        {
            await restartTask.WaitAsync(cancellationToken);
        }
    }

    internal static bool IsSafeBackupArchive(string archivePath)
    {
        try
        {
            var archiveInfo = new FileInfo(archivePath);
            if (!archiveInfo.Exists || archiveInfo.Length is <= 0 or > MaxBackupArchiveBytes)
            {
                return false;
            }

            using var archive = ZipFile.OpenRead(archivePath);
            var configFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (archive.Entries.Count is 0 or > MaxBackupEntries)
            {
                return false;
            }

            long expandedBytes = 0;
            foreach (var entry in archive.Entries)
            {
                if (entry.Length < 0 || entry.Length > MaxBackupExpandedBytes)
                {
                    return false;
                }
                expandedBytes = checked(expandedBytes + entry.Length);
                if (expandedBytes > MaxBackupExpandedBytes)
                {
                    return false;
                }
            }

            foreach (var entry in archive.Entries)
            {
                var relative = entry.FullName.Replace('\\', '/');
                var segments = relative.Split('/', StringSplitOptions.RemoveEmptyEntries);
                if (Path.IsPathRooted(relative)
                    || segments.Any(segment => segment is "." or "..")
                    || relative.Contains(':')
                    || ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000)
                {
                    return false;
                }

                if (entry.Length == 0)
                {
                    continue;
                }

                var guiConfigIndex = Array.IndexOf(segments, "guiConfigs");
                if (guiConfigIndex < 0 || segments.Length != guiConfigIndex + 2)
                {
                    return false;
                }
                if (!configFiles.Add(segments[^1]))
                {
                    return false;
                }
            }

            return configFiles.Contains(Global.ConfigFileName);
        }
        catch
        {
            return false;
        }
    }

    internal static bool TryExtractBackupConfig(string archivePath, string destinationDirectory)
    {
        try
        {
            using var archive = ZipFile.OpenRead(archivePath);
            Directory.CreateDirectory(destinationDirectory);
            foreach (var entry in archive.Entries)
            {
                if (entry.Length == 0)
                {
                    continue;
                }

                var segments = entry.FullName.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
                var guiConfigIndex = Array.IndexOf(segments, "guiConfigs");
                if (guiConfigIndex < 0 || segments.Length != guiConfigIndex + 2)
                {
                    return false;
                }

                var fileName = segments[^1];
                if (string.Equals(fileName, WebAuthFileName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                using var source = entry.Open();
                using var target = new FileStream(
                    Path.Combine(destinationDirectory, fileName),
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None);
                source.CopyTo(target);
            }

            return File.Exists(Path.Combine(destinationDirectory, Global.ConfigFileName));
        }
        catch
        {
            return false;
        }
    }

    internal static void CopyConfigForBackup(string sourceDirectory, string destinationDirectory) =>
        BackupConfigSnapshot.CopyFiles(sourceDirectory, destinationDirectory);

    internal static void PrepareRestoredConfigDirectory(
        string extractedConfigDirectory,
        string currentConfigDirectory,
        string candidateDirectory)
    {
        if (Directory.Exists(currentConfigDirectory))
        {
            CopyConfigDirectory(currentConfigDirectory, candidateDirectory);
        }
        else
        {
            Directory.CreateDirectory(candidateDirectory);
        }

        var replacesDatabase = File.Exists(Path.Combine(extractedConfigDirectory, RestoreDatabaseSnapshot.DatabaseName));
        if (replacesDatabase)
            RestoreDatabaseSnapshot.DeleteSidecars(candidateDirectory);

        foreach (var file in Directory.EnumerateFiles(extractedConfigDirectory, "*", SearchOption.TopDirectoryOnly))
        {
            if (string.Equals(Path.GetFileName(file), WebAuthFileName, StringComparison.OrdinalIgnoreCase)
                || replacesDatabase && RestoreDatabaseSnapshot.IsSidecar(Path.GetFileName(file)))
            {
                continue;
            }

            File.Copy(file, Path.Combine(candidateDirectory, Path.GetFileName(file)), overwrite: true);
        }
    }

    private static void CopyConfigDirectory(string sourceDirectory, string destinationDirectory)
    {
        Directory.CreateDirectory(destinationDirectory);
        foreach (var sourceFile in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.TopDirectoryOnly))
        {
            File.Copy(sourceFile, Path.Combine(destinationDirectory, Path.GetFileName(sourceFile)), overwrite: true);
        }
        foreach (var sourceSubdirectory in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.TopDirectoryOnly))
        {
            CopyConfigDirectory(sourceSubdirectory, Path.Combine(destinationDirectory, Path.GetFileName(sourceSubdirectory)));
        }
    }

    internal static void ReplaceConfigDirectory(string candidateDirectory, string configDirectory, string displacedDirectory)
    {
        var hadCurrentDirectory = Directory.Exists(configDirectory);
        if (hadCurrentDirectory)
        {
            Directory.Move(configDirectory, displacedDirectory);
        }

        try
        {
            Directory.Move(candidateDirectory, configDirectory);
        }
        catch
        {
            if (hadCurrentDirectory && Directory.Exists(displacedDirectory) && !Directory.Exists(configDirectory))
            {
                Directory.Move(displacedDirectory, configDirectory);
            }
            throw;
        }
    }

    private static bool IsValidBackupConfig(string configPath)
    {
        try
        {
            using var document = JsonDocument.Parse(
                File.ReadAllText(configPath),
                new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip });
            return document.RootElement.ValueKind == JsonValueKind.Object
                && JsonSerializer.Deserialize<Config>(document.RootElement.GetRawText(), new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true,
                    ReadCommentHandling = JsonCommentHandling.Skip,
                }) is not null;
        }
        catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static async Task CopyWithLimitAsync(Stream input, Stream output, long limit, CancellationToken cancellationToken)
    {
        var buffer = new byte[81920];
        long total = 0;
        while (true)
        {
            var read = await input.ReadAsync(buffer, cancellationToken);
            if (read == 0)
            {
                return;
            }
            total += read;
            if (total > limit)
            {
                throw new InvalidDataException("The backup archive exceeds the upload size limit.");
            }
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
        }
    }
}
