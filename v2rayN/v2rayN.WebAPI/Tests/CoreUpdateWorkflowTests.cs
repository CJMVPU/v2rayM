using V2rayM.Application.Updates;
using V2rayM.Domain.Updates;
using v2rayN.WebAPI.MacOS;
using System.Formats.Tar;
using System.IO.Compression;
using System.Text;
using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Manager;
using ServiceLib.Resx;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class CoreUpdateWorkflowTests
{
    [Test]
    public async Task LostFinishAcknowledgementDoesNotRollBackCommittedCoreOrClaimHealth()
    {
        var session = new CoreUpdateTestSession { Trusted = TrustedRollbackDisposition.AlreadyCommitted };
        var result = await new CoreUpdateApplyService().RestoreAsync(session, new(true, true, true, true));
        await session.Calls.Contains("restore-files").Should().BeFalse();
        await result.UpdateCommitted.Should().BeTrue();
        await result.Completed.Should().BeFalse();
        await result.CoreRestarted.Should().BeFalse();
        await CoreUpdateApplyService.CommittedUpdateUnconfirmedDetail.Should().Contain("health still requires confirmation");
    }

    [Test]
    public async Task CancellationBeforeTrustedRollbackConfirmationDoesNotRestoreOnlyLocalFiles()
    {
        var session = new CoreUpdateTestSession { FailTrustedRollback = true };
        var result = await new CoreUpdateApplyService().RestoreAsync(session, new(true, true, true, true));
        await result.Completed.Should().BeFalse();
        await result.FilesRestored.Should().BeFalse();
        await session.RecoveryMarked.Should().BeTrue();
        await session.Calls.Contains("restore-files").Should().BeFalse();
    }

    [Test]
    public async Task OldExecutableAliasesCannotShadowTheNewXrayVersion()
    {
        using var directory = new TemporaryDirectory();
        var candidate = Path.Combine(directory.Path, "candidate");
        var package = Path.Combine(directory.Path, "package");
        Directory.CreateDirectory(candidate); Directory.CreateDirectory(package);
        File.WriteAllText(Path.Combine(candidate, "xray-old"), "old binary");
        File.WriteAllText(Path.Combine(candidate, "xray"), "new binary");
        File.WriteAllText(Path.Combine(candidate, "rules.dat"), "retained resource");
        File.WriteAllText(Path.Combine(package, "xray"), "new binary");
        V2rayRuntime.RemoveSupersededCoreExecutables(new ServiceLib.Models.CoreConfigs.CoreInfo { CoreType = ECoreType.Xray, CoreExes = ["xray-old", "xray"] }, candidate, package);
        await File.Exists(Path.Combine(candidate, "xray-old")).Should().BeFalse();
        await File.Exists(Path.Combine(candidate, "xray")).Should().BeTrue();
        await File.Exists(Path.Combine(candidate, "rules.dat")).Should().BeTrue();
    }

    [Test]
    public async Task CoreVersionCheckAcceptsVPrefixedXrayVersion()
    {
        var output = "Xray v26.10.21 darwin arm64 with go1.26.8";

        await CoreExecutableVersionCheck.IsValid(output, "Xray").Should().BeTrue();
    }

    [Test]
    public async Task CoreVersionCheckStillRequiresExpectedNameAndSemanticVersion()
    {
        await CoreExecutableVersionCheck.IsValid("Xray 25.9.11", "Mihomo").Should().BeFalse();
        await CoreExecutableVersionCheck.IsValid("Mihomo Meta development build", "Mihomo").Should().BeFalse();
    }

    [Test]
    public async Task OnlyXrayPackagesAreStaged()
    {
        using var directory = new TemporaryDirectory();

        var xrayArchive = Path.Combine(directory.Path, "xray.zip");
        using (var zip = ZipFile.Open(xrayArchive, ZipArchiveMode.Create))
        {
            await WriteZipFileAsync(zip, "Xray/xray", "xray binary");
            await WriteZipFileAsync(zip, "Xray/geoip.dat", "bundled geo data");
        }
        var xrayStage = Path.Combine(directory.Path, "xray-stage");
        await CoreUpdatePackageStager.ExtractAsync(ECoreType.Xray, xrayArchive, xrayStage, CancellationToken.None);
        await File.Exists(Path.Combine(xrayStage, "xray")).Should().BeTrue();
        await File.Exists(Path.Combine(xrayStage, "geoip.dat")).Should().BeFalse();

        await CoreUpdatePackageStager.IsSupported(ECoreType.mihomo, "mihomo.gz").Should().BeFalse();
        await CoreUpdatePackageStager.IsSupported((ECoreType)24, "retired.tar.gz").Should().BeFalse();

    }

    [Test]
    public async Task ApplyFailureRestoresThePreviousBinaryBeforeRestartingTheOldCore()
    {
        using var directory = new TemporaryDirectory();
        var install = Path.Combine(directory.Path, "xray");
        var backup = Path.Combine(directory.Path, ".xray-backup");
        Directory.CreateDirectory(install);
        Directory.CreateDirectory(backup);
        await File.WriteAllTextAsync(Path.Combine(install, "xray"), "new-binary");
        await File.WriteAllTextAsync(Path.Combine(backup, "xray"), "old-binary");
        var order = new List<string>();

        var session = new CoreUpdateTestSession
        {
            RestoreFiles = () =>
            {
                CoreUpdateFiles.RestorePreviousDirectory(install, backup, candidateInstalled: true, hadInstalledCore: true);
                order.Add("restore-files"); return Task.CompletedTask;
            },
            InitializeOld = () => { order.Add("initialize-old"); return Task.CompletedTask; },
            RestartOld = () => { order.Add("restart-old"); return Task.FromResult(true); },
        };
        var rollback = await new CoreUpdateApplyService().RestoreAsync(session, new(false, true, false, true));

        await rollback.Completed.Should().BeTrue();
        await (await File.ReadAllTextAsync(Path.Combine(install, "xray"))).Should().BeEqualTo("old-binary");
        await order.SequenceEqual(["restore-files", "initialize-old", "restart-old"]).Should().BeTrue();
    }

    [Test]
    public async Task FailedOldCoreRestartIsReportedAfterItsFilesHaveBeenRestored()
    {
        using var directory = new TemporaryDirectory();
        var install = Path.Combine(directory.Path, "xray");
        var backup = Path.Combine(directory.Path, ".xray-backup");
        Directory.CreateDirectory(install);
        Directory.CreateDirectory(backup);
        await File.WriteAllTextAsync(Path.Combine(install, "xray"), "new-binary");
        await File.WriteAllTextAsync(Path.Combine(backup, "xray"), "old-binary");

        var session = new CoreUpdateTestSession
        {
            RestoreFiles = () =>
            {
                CoreUpdateFiles.RestorePreviousDirectory(install, backup, candidateInstalled: true, hadInstalledCore: true);
                return Task.CompletedTask;
            },
            RestartOld = () => Task.FromResult(false),
        };
        var rollback = await new CoreUpdateApplyService().RestoreAsync(session, new(false, true, false, true));

        await rollback.FilesRestored.Should().BeTrue();
        await rollback.Completed.Should().BeFalse();
        await (await File.ReadAllTextAsync(Path.Combine(install, "xray"))).Should().BeEqualTo("old-binary");
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task MissingOrAmbiguousBackupNeverDeletesTheOnlyUsableInstallation(bool ambiguous)
    {
        using var directory = new TemporaryDirectory();
        var install = Path.Combine(directory.Path, "xray");
        var backup = Path.Combine(directory.Path, "backup");
        Directory.CreateDirectory(install);
        await File.WriteAllTextAsync(Path.Combine(install, "xray"), "retained-binary");
        if (ambiguous)
        {
            Directory.CreateDirectory(backup);
            await File.WriteAllTextAsync(Path.Combine(backup, "xray"), "old-binary");
        }
        var failed = false;
        try { CoreUpdateFiles.RestorePreviousDirectory(install, backup, candidateInstalled: !ambiguous, hadInstalledCore: true); }
        catch (IOException) { failed = true; }
        await failed.Should().BeTrue();
        await (await File.ReadAllTextAsync(Path.Combine(install, "xray"))).Should().BeEqualTo("retained-binary");
        if (ambiguous) await (await File.ReadAllTextAsync(Path.Combine(backup, "xray"))).Should().BeEqualTo("old-binary");
    }

    [Test]
    public async Task OnlyXrayCanBeInstalled()
    {
        await CoreUpdatePackageStager.SupportsCore(ECoreType.Xray).Should().BeTrue();
        await CoreUpdatePackageStager.SupportsCore((ECoreType)24).Should().BeFalse();
        await CoreUpdatePackageStager.SupportsCore(ECoreType.mihomo).Should().BeFalse();
        await CoreUpdatePackageStager.SupportsCore(ECoreType.v2rayN).Should().BeFalse();
    }

    [Test]
    public async Task CoreUpdatePreReleaseChoicesMatchDesktopCoreInfoSemantics()
    {
        var manager = CoreInfoManager.Instance;
        await manager.GetCheckPreRelease(ECoreType.Xray, true).Should().BeTrue();
        await manager.GetCheckPreRelease(ECoreType.v2rayN, true).Should().BeTrue();
        await manager.GetCheckPreRelease(ECoreType.mihomo, true).Should().BeFalse();
        await manager.GetCheckPreRelease((ECoreType)24, true).Should().BeFalse();
        await manager.GetCheckPreRelease((ECoreType)24, false).Should().BeFalse();
    }

    [Test]
    public async Task RetiredEnginesAreRejectedEvenWhenTheirVersionOutputIsValid()
    {
        await CoreExecutableVersionCheck.IsValid("Mihomo Meta alpha-94b13ae darwin arm64 with go1.26.8", "Mihomo").Should().BeFalse();
        await CoreExecutableVersionCheck.IsValid("Mihomo Meta v1.19.31", "Mihomo").Should().BeFalse();
        await CoreExecutableVersionCheck.IsValid("Mihomo Meta alpha-development build", "Mihomo").Should().BeFalse();
        await CoreExecutableVersionCheck.IsValid("Mihomo Meta alpha-94b13ae", "Xray").Should().BeFalse();
    }

    [Test]
    public async Task CoreUpdateCheckPreservesServiceLibCurrentVersionSemantics()
    {
        var latest = string.Format(ResUI.IsLatestCore, ECoreType.Xray, "v1.2.3");
        await V2rayRuntime.IsUpToDateResult(ECoreType.Xray, latest).Should().BeTrue();
        await V2rayRuntime.IsUpToDateResult(ECoreType.Xray, "Could not reach release API").Should().BeFalse();
        await V2rayRuntime.IsUpToDateResult(ECoreType.Xray, null).Should().BeFalse();
    }

    private static async Task WriteZipFileAsync(ZipArchive zip, string name, string content)
    {
        await using var stream = zip.CreateEntry(name).Open();
        await stream.WriteAsync(Encoding.UTF8.GetBytes(content));
    }

    private static async Task WriteGzipAsync(string path, string content)
    {
        await using var file = File.Create(path);
        await using var gzip = new GZipStream(file, CompressionLevel.SmallestSize);
        await gzip.WriteAsync(Encoding.UTF8.GetBytes(content));
    }

    private static async Task WriteTarGzipAsync(string path, string entryName, string content)
    {
        await using var file = File.Create(path);
        await using var gzip = new GZipStream(file, CompressionLevel.SmallestSize, leaveOpen: true);
        using var writer = new TarWriter(gzip, TarEntryFormat.Pax, leaveOpen: true);
        var entry = new PaxTarEntry(TarEntryType.RegularFile, entryName)
        {
            DataStream = new MemoryStream(Encoding.UTF8.GetBytes(content)),
        };
        writer.WriteEntry(entry);
        await Task.CompletedTask;
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"v2rayn-WebAPI-core-update-test-{Guid.NewGuid():N}");
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose() => Directory.Delete(Path, recursive: true);
    }
}
