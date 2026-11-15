namespace ServiceLib.Tests.Manager;

public class ProfileExSortTests
{
    [Test]
    public async Task CachedMaximumTracksLoweringTiesAndNewEntries()
    {
        var manager = new ProfileExManager();
        await manager.GetMaxSort().Should().BeEqualTo(0);
        manager.SetSort("a", 20);
        manager.SetSort("b", 20);
        await manager.GetMaxSort().Should().BeEqualTo(20);
        manager.SetSort("a", 10);
        await manager.GetMaxSort().Should().BeEqualTo(20);
        manager.SetSort("b", -10);
        await manager.GetMaxSort().Should().BeEqualTo(10);
        manager.SetSort("a", -20);
        await manager.GetMaxSort().Should().BeEqualTo(-10);
        manager.SetTestDelay("new", 50);
        await manager.GetMaxSort().Should().BeEqualTo(0);
        manager.SetSort("new", 30);
        manager.SetTestSpeed("new", 100);
        await manager.GetMaxSort().Should().BeEqualTo(30);
    }
}
