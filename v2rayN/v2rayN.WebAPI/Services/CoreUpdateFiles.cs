using ServiceLib.Common;
using ServiceLib.Models.CoreConfigs;

namespace v2rayN.WebAPI.Services;

internal static class CoreUpdateFiles
{
    public static void RestorePreviousDirectory(
        string installPath,
        string backupPath,
        bool candidateInstalled,
        bool hadInstalledCore)
    {
        // Prove that the previous installation is recoverable before deleting
        // the candidate. Missing/ambiguous backups must preserve the evidence.
        if (hadInstalledCore)
        {
            if (!Directory.Exists(backupPath))
            {
                if (candidateInstalled || !Directory.Exists(installPath))
                    throw new IOException("The previous Core backup is missing; the current directory was retained.");
                return; // Replacement never moved the original installation.
            }
            if (!candidateInstalled && Directory.Exists(installPath))
                throw new IOException("Both the previous backup and an unclassified installation exist; neither was changed.");
        }
        if (candidateInstalled && Directory.Exists(installPath))
        {
            Directory.Delete(installPath, recursive: true);
        }
        if (hadInstalledCore && Directory.Exists(backupPath) && !Directory.Exists(installPath))
        {
            Directory.Move(backupPath, installPath);
        }
    }


    public static string? FindCoreExecutable(CoreInfo coreInfo, string directory) =>
        (coreInfo.CoreExes ?? [])
            .Select(name => Path.Combine(directory, Utils.GetExeName(name)))
            .FirstOrDefault(File.Exists);

    public static void RemoveSupersededCoreExecutables(CoreInfo info, string candidate, string package)
    {
        var replacement = FindCoreExecutable(info, package)
            ?? throw new InvalidDataException("The replacement package has no core executable.");
        foreach (var name in info.CoreExes ?? [])
        {
            var fileName = Utils.GetExeName(name);
            if (fileName == Path.GetFileName(replacement)) continue;
            var oldAlias = Path.Combine(candidate, fileName);
            if (File.Exists(oldAlias)) File.Delete(oldAlias);
        }
    }

    public static void CopyCoreDirectory(string sourceDirectory, string destinationDirectory)
    {
        Directory.CreateDirectory(destinationDirectory);
        foreach (var sourceFile in Directory.EnumerateFiles(sourceDirectory, "*", SearchOption.TopDirectoryOnly))
        {
            File.Copy(sourceFile, Path.Combine(destinationDirectory, Path.GetFileName(sourceFile)), overwrite: true);
        }
        foreach (var sourceSubdirectory in Directory.EnumerateDirectories(sourceDirectory, "*", SearchOption.TopDirectoryOnly))
        {
            CopyCoreDirectory(sourceSubdirectory, Path.Combine(destinationDirectory, Path.GetFileName(sourceSubdirectory)));
        }
    }

    public static void CopyLatestGeoFilesForApply(string installPath, string stagingPath)
    {
        if (!Directory.Exists(installPath))
        {
            return;
        }
        foreach (var source in Directory.EnumerateFiles(installPath, "geo*", SearchOption.TopDirectoryOnly))
        {
            File.Copy(source, Path.Combine(stagingPath, Path.GetFileName(source)), overwrite: true);
        }
    }
}
