using ServiceLib.Tests.CoreConfig;

namespace ServiceLib.Tests.Handler;

[NotInParallel]
public class SubscriptionOutcomeTests
{
    [Test]
    public async Task CaughtHeaderFailureAndDisabledSubscriptionReturnDifferentOutcomes()
    {
        TestDatabase.Initialize();
        var prefix = Guid.NewGuid().ToString("N");
        var bad = new SubItem { Id = prefix, Enabled = true, Url = "https://example.invalid/sub", RequestHeaders = "invalid header" };
        var disabled = new SubItem { Id = prefix + "-off", Enabled = false, Url = bad.Url };
        try
        {
            await SQLiteHelper.Instance.InsertAsync(bad);
            await SQLiteHelper.Instance.InsertAsync(disabled);
            var config = CoreConfigTestFactory.CreateConfig();
            var failed = await SubscriptionHandler.UpdateProcessWithResults(config, bad.Id, false, (_, _) => Task.CompletedTask);
            var skipped = await SubscriptionHandler.UpdateProcessWithResults(config, disabled.Id, false, (_, _) => Task.CompletedTask);
            await failed.Single().Kind.Should().BeEqualTo(SubscriptionUpdateOutcomeKind.Failed);
            await skipped.Single().Kind.Should().BeEqualTo(SubscriptionUpdateOutcomeKind.Skipped);
        }
        finally
        {
            await SQLiteHelper.Instance.DeleteAsync(bad);
            await SQLiteHelper.Instance.DeleteAsync(disabled);
        }
    }
}
