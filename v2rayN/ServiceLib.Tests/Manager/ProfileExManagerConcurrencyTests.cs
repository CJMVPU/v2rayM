namespace ServiceLib.Tests.Manager;

public class ProfileExManagerConcurrencyTests
{
    [Test]
    public async Task SetTestDelay_FromManyThreads_ShouldNotThrow()
    {
        var manager = CreateManager();
        var exceptions = new List<Exception>();
        var threads = Environment.ProcessorCount * 2;

        // Hammer the same manager from several streams while creating and updating records.
        var barrier = new Barrier(threads);
        Parallel.For(0, threads, t =>
        {
            barrier.SignalAndWait();
            for (var i = 0; i < 5000; i++)
            {
                try
                {
                    manager.SetTestDelay($"index{i % 500}", i);
                }
                catch (Exception ex)
                {
                    lock (exceptions)
                    {
                        exceptions.Add(ex);
                    }
                }
            }
        });

        await exceptions.Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task SetTestDelay_FromManyThreads_ShouldNotLoseEntries()
    {
        var manager = CreateManager();
        var ids = 500;

        Parallel.For(0, Environment.ProcessorCount * 2, t =>
        {
            for (var i = 0; i < 5000; i++)
            {
                manager.SetTestDelay($"id{i % ids}", i);
            }
        });

        var snapshot = await manager.GetProfileExs();
        await snapshot.Count.Should().BeEqualTo(ids);
        await snapshot.Select(item => item.IndexId).Distinct().Count().Should().BeEqualTo(ids);
    }

    [Test]
    public async Task SetTestDelay_ShouldCreateOneEntryPerIndex()
    {
        var manager = CreateManager();

        await Parallel.ForEachAsync(Enumerable.Range(0, 500), new ParallelOptions { MaxDegreeOfParallelism = 32 },
            async (i, ct) =>
            {
                manager.SetTestDelay($"same{i % 10}", i);
                await Task.CompletedTask;
            });

        var items = await manager.GetProfileExs();
        await items.Count.Should().BeEqualTo(10);
        await items.Select(t => t.IndexId).Distinct().Count().Should().BeEqualTo(10);
    }

    private static ProfileExManager CreateManager()
    {
        return (ProfileExManager)Activator.CreateInstance(typeof(ProfileExManager), nonPublic: true)!;
    }

}
