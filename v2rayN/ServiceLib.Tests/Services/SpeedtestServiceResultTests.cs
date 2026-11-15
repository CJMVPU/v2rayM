namespace ServiceLib.Tests.Services;

public class SpeedtestServiceResultTests
{
    [Test]
    [Arguments(ESpeedActionType.Speedtest, 0)]
    [Arguments(ESpeedActionType.Mixedtest, 0)]
    [Arguments(ESpeedActionType.Realping, 12.5)]
    public async Task StartingATest_ShouldClearTheLastSpeedOfSpeedTests(ESpeedActionType actionType, double expected)
    {
        var indexId = Guid.NewGuid().ToString();
        ProfileExManager.Instance.SetTestSpeed(indexId, 12.5m);

        await SetTestResult([new() { IndexId = indexId }], actionType, ResUI.Speedtesting);

        var profileEx = (await ProfileExManager.Instance.GetProfileExs()).First(t => t.IndexId == indexId);
        await profileEx.Speed.Should().BeEqualTo((decimal)expected);
    }

    [Test]
    [Arguments("de-DE")]
    [Arguments("fr-FR")]
    [Arguments("en-US")]
    public async Task DownloadSpeed_ShouldPreserveDecimalValueAcrossCultures(string cultureName)
    {
        var originalCulture = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new(cultureName);
            var format = typeof(DownloaderHelper).GetMethod("FormatSpeedTestResult", BindingFlags.Static | BindingFlags.NonPublic)!;
            var message = (string)format.Invoke(null, [1_500_000d])!;
            var indexId = Guid.NewGuid().ToString();
            SpeedTestResult? observed = null;
            var service = new SpeedtestService(new Config { SpeedTestItem = new() }, result =>
            {
                observed = result;
                return Task.CompletedTask;
            });
            var apply = typeof(SpeedtestService).GetMethod("ApplySpeedTestResultAsync", BindingFlags.Instance | BindingFlags.NonPublic)!;
            await (Task)apply.Invoke(service, [indexId, message])!;

            var profile = (await ProfileExManager.Instance.GetProfileExs()).First(item => item.IndexId == indexId);
            await profile.Speed.Should().BeEqualTo(1.5m);
            await observed!.Speed.Should().BeEqualTo("1.5");
            // Match the WebAPI wire-value parser, including cultures with comma decimals.
            var apiSpeed = decimal.Parse(observed.Speed!, System.Globalization.NumberStyles.Number,
                System.Globalization.CultureInfo.InvariantCulture);
            await apiSpeed.Should().BeEqualTo(1.5m);
        }
        finally
        {
            System.Globalization.CultureInfo.CurrentCulture = originalCulture;
        }
    }

    private static Task SetTestResult(List<ServerTestItem> items, ESpeedActionType actionType, string message)
    {
        var service = new SpeedtestService(new Config { SpeedTestItem = new() }, _ => Task.CompletedTask);
        var method = typeof(SpeedtestService).GetMethod("SetTestResultAsync", BindingFlags.Instance | BindingFlags.NonPublic)!;
        return (Task)method.Invoke(service, [items, actionType, message])!;
    }
}
