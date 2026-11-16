using V2rayM.Application.Profiles;

namespace v2rayN.WebAPI.Tests;

public class ProfileQueryApplicationTests
{
    [Test]
    public async Task FastObservationsDoNotReadNodeDocuments()
    {
        var source = new Source();
        await new ProfileQueryService(source).ObserveAsync();
        await source.FullReads.Should().BeEqualTo(0);
    }

    [Test]
    public async Task CountQueryMatchesLargeCatalogWithoutMaterializingDocuments()
    {
        var path = Path.Combine(Path.GetTempPath(), "v2raym-count-" + Guid.NewGuid().ToString("N") + ".db");
        var database = new ServiceLib.Helper.SQLiteHelper(path);
        try
        {
            database.CreateTable<ServiceLib.Models.Entities.ProfileItem>();
            database.CreateTable<ServiceLib.Models.Entities.SubItem>();
            await database.InsertAllAsync(Enumerable.Range(0, 10000).Select(index => new ServiceLib.Models.Entities.ProfileItem
            { IndexId = index.ToString(), Remarks = new string('x', 256), Address = "example.invalid", Subid = "group" }).ToArray());
            await database.InsertAsync(new ServiceLib.Models.Entities.SubItem { Id = "group" });
            var watch = System.Diagnostics.Stopwatch.StartNew();
            var materialized = await database.TableAsync<ServiceLib.Models.Entities.ProfileItem>().ToListAsync();
            var full = watch.Elapsed.TotalMilliseconds;
            watch.Restart();
            var counts = await v2rayN.WebAPI.Adapters.Profiles.ServiceLibProfileQueries.CountAsync(database);
            Console.WriteLine($"Catalog 10000 nodes: full read {full:F2} ms; counts {watch.Elapsed.TotalMilliseconds:F2} ms");
            await counts.Profiles.Should().BeEqualTo(materialized.Count);
            await counts.Subscriptions.Should().BeEqualTo(1);
        }
        finally { await database.DisposeDbConnectionAsync(); File.Delete(path); }
    }
    [Test]
    public async Task TrimmedFilterMatchesNameOrAddressAndKeepsStableSort()
    {
        var source = new Source(); var service = new ProfileQueryService(source);
        var rows = await service.ListAsync(null, " match ");
        await string.Join(",", rows.Select(row => row.IndexId)).Should().BeEqualTo("address,name");
        await rows[0].TotalDown.Should().BeEqualTo(99);
        await rows[0].CoreType.Should().BeEqualTo("unknown-stored-core");
    }
    [Test]
    public async Task GroupCountsIncludeManualAndOrphanNodesWithoutReadingTelemetry()
    {
        var source = new Source(); var service = new ProfileQueryService(source);
        var groups = await service.GroupsAsync();
        await source.FullReads.Should().BeEqualTo(0);
        await groups[0].Count.Should().BeEqualTo(4);
        await groups.Single(group => group.Id == "group").Count.Should().BeEqualTo(2);
        await groups.Single(group => group.Id == "empty").Count.Should().BeEqualTo(0);
        await groups.Single(group => group.Id == "empty").Selected.Should().BeTrue();
    }
    private sealed class Source : IProfileQuerySource
    {
        public int FullReads;
        private static ProfileListEntry Entry(string id, string name, string address, int sort) =>
            new(id, name, "socks", address, 1080, "tcp", "", "group", "Group", "unknown-stored-core", sort,
                12, 13, null, 1, 2, 3, 99, false, true);
        public Task<IReadOnlyList<ProfileListEntry>> CaptureAsync(string? group, bool includeStatistics = true)
        {
            FullReads++;
            return Task.FromResult<IReadOnlyList<ProfileListEntry>>([Entry("name", "match", "host", 2),
                Entry("address", "other", "match", 1), Entry("excluded", "other", "host", 0)]);
        }
        public Task<IReadOnlyList<ProfileObservation>> ObserveAsync() => Task.FromResult<IReadOnlyList<ProfileObservation>>([]);
        public Task<ProfileGroupSnapshot> CaptureGroupsAsync() => Task.FromResult(new ProfileGroupSnapshot(
            ["group", "group", "", "orphan"], [new("group", "Group"), new("empty", "Empty")], "empty"));
        public bool Matches(string value, string query) => value.Contains(query, StringComparison.Ordinal);
    }
}
