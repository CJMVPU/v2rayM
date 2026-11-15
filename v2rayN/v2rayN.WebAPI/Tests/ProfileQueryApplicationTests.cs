using V2rayM.Application.Profiles;

namespace v2rayN.WebAPI.Tests;

public class ProfileQueryApplicationTests
{
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
        public Task<ProfileQuerySnapshot> CaptureAsync(string? group)
        {
            FullReads++;
            return Task.FromResult(new ProfileQuerySnapshot([Entry("name", "match", "host", 2),
                Entry("address", "other", "match", 1), Entry("excluded", "other", "host", 0)], [], ""));
        }
        public Task<ProfileGroupSnapshot> CaptureGroupsAsync() => Task.FromResult(new ProfileGroupSnapshot(
            ["group", "group", "", "orphan"], [new("group", "Group"), new("empty", "Empty")], "empty"));
        public bool Matches(string value, string query) => value.Contains(query, StringComparison.Ordinal);
    }
}
