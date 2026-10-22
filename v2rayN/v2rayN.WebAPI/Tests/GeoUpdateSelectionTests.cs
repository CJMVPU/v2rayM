using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class GeoUpdateSelectionTests
{
    [Test]
    public async Task OnlyXrayDatFilesCanBeUpdated()
    {
        string[] files = ["/fixture/geoip.dat", "/fixture/geosite.dat", "/fixture/Country.mmdb", "/fixture/srss/geosite-cn.srs"];
        var geo = GeoUpdateSelection.Filter(files, "geo");
        var rules = GeoUpdateSelection.Filter(files, "rules");
        await geo.SequenceEqual(files.Take(2)).Should().BeTrue();
        await rules.SequenceEqual(files.Take(2)).Should().BeTrue();
        await geo.SequenceEqual(rules).Should().BeTrue();
        await GeoUpdateSelection.Filter(files, "all").SequenceEqual(files.Take(2)).Should().BeTrue();
        await GeoUpdateSelection.IsValid("unknown").Should().BeFalse();
    }
}
