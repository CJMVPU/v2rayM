namespace V2rayM.Domain.Updates;

public sealed record UpdatePreferences(IReadOnlyList<string>? SelectedTargets,
    IReadOnlyList<string>? PreReleaseTargets, bool UseProxy);

public sealed record UpdatePreferenceRequest(IReadOnlyList<string>? SelectedTargets,
    IReadOnlyList<string>? PreReleaseTargets, bool LegacyPreRelease, bool UseProxy);

/// Visible selections replace only the editable portion of a stored preference.
/// Unknown stored targets remain available to a future version/platform.
public sealed class UpdatePreferencePolicy(IEnumerable<string> supportedTargets, IEnumerable<string> preReleaseTargets)
{
    public const string GeoTarget = "GeoFiles";
    private readonly HashSet<string> _supported = supportedTargets.Append(GeoTarget).ToHashSet(StringComparer.Ordinal);
    private readonly HashSet<string> _preRelease = preReleaseTargets.ToHashSet(StringComparer.Ordinal);

    private static string[]? Distinct(IEnumerable<string>? targets) => targets?.Distinct(StringComparer.Ordinal).ToArray();

    public UpdatePreferences? Validate(UpdatePreferenceRequest request)
    {
        var selected = Distinct(request.SelectedTargets) ?? [];
        // An explicit empty list overrides the old single switch.
        var preRelease = Distinct(request.PreReleaseTargets) ?? (request.LegacyPreRelease ? _preRelease.ToArray() : []);
        if (selected.Any(target => !_supported.Contains(target)) || preRelease.Any(target => !_preRelease.Contains(target))) return null;
        return new(selected, preRelease, request.UseProxy);
    }

    public UpdatePreferences Merge(UpdatePreferences previous, UpdatePreferences validated) => new(
        MergeTargets(previous.SelectedTargets, validated.SelectedTargets, _supported),
        MergeTargets(previous.PreReleaseTargets, validated.PreReleaseTargets, _preRelease), validated.UseProxy);

    private static string[] MergeTargets(IEnumerable<string>? previous, IEnumerable<string>? requested, HashSet<string> visible) =>
        (Distinct(previous) ?? []).Where(target => !visible.Contains(target))
            .Concat(requested ?? []).Distinct(StringComparer.Ordinal).ToArray();
}
