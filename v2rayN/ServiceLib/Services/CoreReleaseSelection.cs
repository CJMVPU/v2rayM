namespace ServiceLib.Services;

/// A prerelease channel includes stable releases too: promoting the newest
/// release to stable must never send clients back to an older prerelease.
public static class CoreReleaseSelection
{
    public static GitHubRelease? Select(IEnumerable<GitHubRelease>? releases, bool includePrerelease,
        SemanticVersion? maximumVersion = null) => releases?
        .Where(r => !r.Draft && r.Assets is { Count: > 0 } && (includePrerelease || !r.Prerelease))
        .Select(r => new { Release = r, Valid = SemanticVersion.TryParse(r.TagName, out var v), Version = v })
        .Where(r => r.Valid && r.Version is not null && (maximumVersion is null || r.Version <= maximumVersion))
        .OrderByDescending(r => r.Version)
        .ThenByDescending(r => r.Release.PublishedAt)
        .Select(r => r.Release)
        .FirstOrDefault();

}
