namespace V2rayM.Domain.Routing;

public sealed record RoutingProfileSettings(string? Name, string? Url, bool Enabled, bool Locked,
    string? Icon, string? DomainStrategy, string Rules);

public sealed record ActiveRoutingConfiguration(string Id, string? Rules, bool Enabled, string? DomainStrategy);

public static class RoutingProfilePolicy
{
    public static int NewSort(int requested, IEnumerable<int> existing) =>
        requested > 0 ? requested : existing.DefaultIfEmpty(0).Max() + 1;
}
