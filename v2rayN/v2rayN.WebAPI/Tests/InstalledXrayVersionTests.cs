using v2rayN.WebAPI.Services;
namespace v2rayN.WebAPI.Tests;
public class InstalledXrayVersionTests
{
    [Test]
    public async Task AcceptsOnlyActualXrayVersionOutput()
    {
        await InstalledXrayVersion.Parse("Xray 26.10.21 (Xray, Penetrates Everything.) abc\nhelp").Should().BeEqualTo("26.10.21");
        await InstalledXrayVersion.Parse("Xray 26.10.21-beta.1 (Xray)").Should().BeEqualTo("26.10.21-beta.1");
        await InstalledXrayVersion.Parse("Xray 26.10.21 (Xray) 1b1647c-v2raym-darwin-bind1").Should().BeEqualTo("26.10.21（修复版 M1）");
        await InstalledXrayVersion.Parse("Xray 26.10.21 (Xray) 1b1647c-v2raym-darwin-bind2 (go1.27.3 darwin/arm64)").Should().BeEqualTo("26.10.21（修复版 M2）");
        await InstalledXrayVersion.Parse("Xray 26.10.21 (Xray) 1b1647c-v2raym-darwin-bind20").Should().BeEqualTo("26.10.21");
        await (InstalledXrayVersion.Parse("download failed 26.10.21") is null).Should().BeTrue();
        await (InstalledXrayVersion.Parse(null) is null).Should().BeTrue();
    }
    [Test]
    public async Task MissingBinaryDoesNotReportInstalledVersion()
    {
        var reader = new InstalledXrayVersion();
        await (await reader.ReadAsync(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString())) is null).Should().BeTrue();
    }
    [Test]
    public async Task CachesPollingButRefreshesAfterExecutableReplacement()
    {
        var file = Path.GetTempFileName();
        try
        {
            var calls = 0;
            var reader = new InstalledXrayVersion((_, _) => Task.FromResult<string?>(++calls == 1 ? "Xray 26.10.21 build" : "Xray 26.10.22 build"));
            await (await reader.ReadAsync(file)).Should().BeEqualTo("26.10.21");
            await (await reader.ReadAsync(file)).Should().BeEqualTo("26.10.21");
            await calls.Should().BeEqualTo(1);
            await File.WriteAllTextAsync(file, "replacement");
            await (await reader.ReadAsync(file)).Should().BeEqualTo("26.10.22");
            await calls.Should().BeEqualTo(2);
        }
        finally { File.Delete(file); }
    }

}
