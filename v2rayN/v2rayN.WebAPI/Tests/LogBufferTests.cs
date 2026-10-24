using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class LogBufferTests
{
    [Test]
    public async Task PathologicalFilterUsesOneBudgetAndDoesNotHoldTheWriteLock()
    {
        var logs = new LogBuffer();
        for (var index = 0; index < 2; index++) logs.Add("core", new string('a', 100) + "!");
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var query = Task.Run(() => logs.RecentPage(1, 100, "(a+)+$"));
        await Task.Delay(100);
        var write = Task.Run(() => logs.Add("core", "still writable"));
        await write.WaitAsync(TimeSpan.FromSeconds(1));
        var result = await query.WaitAsync(TimeSpan.FromSeconds(1));
        await (watch.Elapsed < TimeSpan.FromSeconds(2)).Should().BeTrue();
        await (result.Items.Count >= 2).Should().BeTrue();
    }

    [Test]
    public async Task HighVolumeRetentionRemainsBoundedAndClearDropsAllEntries()
    {
        var logs = new LogBuffer();
        for (var index = 0; index < 50_000; index++)
        {
            logs.Add("core", $"line {index}");
        }

        var retained = logs.Recent(2000);
        await retained.Count.Should().BeEqualTo(2000);
        await retained[^1].Message.Should().BeEqualTo("line 49999");

        logs.Clear();
        await logs.Recent(2000).Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task OversizedLogMessagesAreTruncatedAtTheBufferBoundary()
    {
        var logs = new LogBuffer();
        var entry = logs.Add("core", new string('x', 100_000));

        await entry.Message.Length.Should().BeLessThanOrEqualTo(16 * 1024);
        await entry.Message.Should().Contain("log entry truncated");
    }

    [Test]
    public async Task CharacterRetentionIsBoundedIndependentlyOfEntryCount()
    {
        var logs = new LogBuffer();
        var message = new string('x', 10_000);
        for (var index = 0; index < 1000; index++) logs.Add("core", message);

        var retained = logs.Recent(2000);
        await retained.Count.Should().BeLessThan(2000);
        await retained.Sum(item => item.Message.Length + item.Source.Length)
            .Should().BeLessThanOrEqualTo(LogBuffer.MaximumRetainedCharacters);
    }

    [Test]
    public async Task TenThousandRowsAreRetainedInOrderAndOnlyOldestRowsAreEvicted()
    {
        var logs = new LogBuffer();
        for (var index = 0; index < 10_005; index++) logs.Add("core", $"line {index}");
        var retained = logs.Recent(10_000);
        await retained.Count.Should().BeEqualTo(10_000);
        await retained[0].Message.Should().BeEqualTo("line 5");
        await retained[^1].Message.Should().BeEqualTo("line 10004");
    }

    [Test]
    public async Task IncrementalPollingDoesNotReplaceOrDuplicateOldRows()
    {
        var logs = new LogBuffer();
        var first = logs.Add("core", "before stop");
        var initial = logs.Tail(0, 10_000);
        await initial.Items.Single().Sequence.Should().BeEqualTo(first.Sequence);
        await logs.Tail(initial.LatestSequence, 10_000).Items.Count.Should().BeEqualTo(0);
        var second = logs.Add("core", "after restart");
        var next = logs.Tail(initial.LatestSequence, 10_000);
        await next.Items.Single().Sequence.Should().BeEqualTo(second.Sequence);
        await logs.Recent(10_000).Count.Should().BeEqualTo(2);
    }

    [Test]
    public async Task CursorFromAnEarlierBackendSessionReturnsAvailableHistory()
    {
        var logs = new LogBuffer();
        logs.Add("core", "new backend");
        await logs.Tail(1000, 10_000).Items.Single().Message.Should().BeEqualTo("new backend");
    }

    [Test]
    public async Task ClearingLogsAdvancesGenerationForRejectingStaleRealtimeEntries()
    {
        var logs = new LogBuffer();
        var previous = logs.Add("core", "old entry");
        var generation = logs.Clear();
        var current = logs.Add("core", "new entry");

        await previous.Generation.Should().BeEqualTo(0);
        await generation.Should().BeEqualTo(1);
        await current.Generation.Should().BeEqualTo(1);
    }
}
