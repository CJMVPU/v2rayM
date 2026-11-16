namespace ServiceLib.Tests.Handler;

public class ConfigLoadFailureTests
{
    [Test]
    [Arguments("{")]
    [Arguments("null")]
    [Arguments("{\"inbound\":\"not-an-array\"}")]
    [Arguments("")]
    public async Task InvalidExistingFileIsNotReplacedWithDefaults(string content)
    {
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-config-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "guiNConfig.json");
        try
        {
            await File.WriteAllTextAsync(path, content);
            await (ConfigTextHandler.LoadConfig(path) is null).Should().BeTrue();
            await (await File.ReadAllTextAsync(path)).Should().BeEqualTo(content);
        }
        finally { Directory.Delete(directory, true); }
    }

    [Test]
    public async Task OnlyMissingConfigurationCreatesDefaultsAndValidDataKeepsValues()
    {
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-config-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "guiNConfig.json");
        try
        {
            await (ConfigTextHandler.LoadConfig(path) is not null).Should().BeTrue();
            await File.Exists(path).Should().BeFalse();
            const string json = "{\"indexId\":\"selected\",\"inbound\":[{\"localPort\":23456}]}";
            await File.WriteAllTextAsync(path, json);
            var loaded = ConfigTextHandler.LoadConfig(path)!;
            await loaded.IndexId.Should().BeEqualTo("selected");
            await loaded.Inbound[0].LocalPort.Should().BeEqualTo(23456);
            await (await File.ReadAllTextAsync(path)).Should().BeEqualTo(json);
        }
        finally { Directory.Delete(directory, true); }
    }
}
