namespace v2rayN.WebAPI.Services;

internal static class GeoUpdateSelection
{
    public static bool IsValid(string scope) => scope is "all" or "geo" or "rules";
    public static string[] Filter(IEnumerable<string> managedFiles, string scope)
    {
        if (!IsValid(scope)) throw new ArgumentException("Invalid Geo update scope.", nameof(scope));
        // Xray consumes both routing datasets for each supported update scope.
        return managedFiles.Where(path => Path.GetFileName(path) is "geoip.dat" or "geosite.dat").ToArray();
    }
}
