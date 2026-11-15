using Microsoft.Extensions.Configuration;
using v2rayN.WebAPI.Contracts;
using v2rayN.WebAPI.Launcher;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class BackupRestorePreflightTests
{
    [Test]
    [Arguments("https://127.0.0.1:5443", "/usr/bin/setsid", "backup_restore_health_probe_unavailable")]
    [Arguments("http://192.168.1.20:5080", "/usr/bin/setsid", "backup_restore_health_probe_unavailable")]
    [Arguments("http://127.0.0.1:5080", null, "backup_restore_setsid_unavailable")]
    public async Task InvalidRestartEnvironmentCannotEnterRestoreUseCase(string listener, string? setsid, string code)
    {
        var preflight = CreatePreflight(listener, setsid);
        var session = new RestoreTestSession { Admission = new(preflight.Allowed,
            preflight.Owner == WebLifecycleOwner.NativeProcess, preflight.Replacement is not null) };
        var result = await new V2rayM.Application.Backups.BackupRestoreService(session).RestoreAsync(default);
        await result.Status.Should().BeEqualTo(V2rayM.Application.Backups.BackupRestoreStatus.PreflightRejected);
        await preflight.ToFailureOperation().Code.Should().BeEqualTo(code);
        await session.Actions.Contains("backup").Should().BeFalse();
        await session.Actions.Contains("stop").Should().BeFalse();
        await session.Actions.Contains("replace").Should().BeFalse();
    }

    [Test]
    public async Task NativeWindowsRestoreBuildsVerifiedHiddenReplacementWithoutSetsid()
    {
        var preflight = NativeWebRestorePreflight.Evaluate(
            Config(("urls", "http://localhost:5080")),
            isLinux: false,
            isWindows: true,
            externalSupervisor: false,
            containerEnvironment: false,
            setsidPath: null,
            processPath: @"C:\WebAPI\v2rayN.WebAPI.exe",
            managedEntryPoint: null,
            hostArguments: ["--urls", "http://localhost:5080"],
            fileExists: _ => true);

        await preflight.Allowed.Should().BeTrue();
        await preflight.Owner.Should().BeEqualTo(WebLifecycleOwner.NativeProcess);
        await preflight.Replacement!.HealthUri.ToString().Should().BeEqualTo("http://localhost:5080/api/health");
        await preflight.Replacement.Command.CreateNoWindow.Should().BeTrue();
        await preflight.Replacement.Command.LauncherPath.Should().BeEqualTo(Path.GetFullPath(@"C:\WebAPI\v2rayN.WebAPI.exe"));
        await preflight.Replacement.Command.Arguments.SequenceEqual([
            WebLaunchOptions.BackgroundChildFlag,
            "--urls",
            "http://localhost:5080",
        ]).Should().BeTrue();
        await preflight.Replacement.Command.ToProcessStartInfo().UseShellExecute.Should().BeFalse();
    }

    [Test]
    public async Task ExternalSupervisorOwnsRestartAndDoesNotRequireANativeHealthProbeOrLauncher()
    {
        var preflight = NativeWebRestorePreflight.Evaluate(
            Config(("urls", "https://127.0.0.1:5443")),
            isLinux: true,
            isWindows: false,
            externalSupervisor: true,
            containerEnvironment: false,
            setsidPath: null,
            processPath: null,
            managedEntryPoint: null,
            hostArguments: []);

        await preflight.Allowed.Should().BeTrue();
        await preflight.Owner.Should().BeEqualTo(WebLifecycleOwner.ExternalSupervisor);
        await (preflight.Replacement is null).Should().BeTrue();
    }

    private static NativeWebRestorePreflightResult CreatePreflight(string listener, string? setsidPath) =>
        NativeWebRestorePreflight.Evaluate(
            Config(("urls", listener)),
            isLinux: true,
            isWindows: false,
            externalSupervisor: false,
            containerEnvironment: false,
            setsidPath,
            processPath: "/opt/v2rayN.WebAPI",
            managedEntryPoint: null,
            hostArguments: [],
            fileExists: _ => true,
            isUnixExecutable: _ => true);

    private static IConfigurationRoot Config(params (string Key, string Value)[] values) =>
        new ConfigurationBuilder()
            .AddInMemoryCollection(values.ToDictionary(item => item.Key, item => (string?)item.Value))
            .Build();

}
