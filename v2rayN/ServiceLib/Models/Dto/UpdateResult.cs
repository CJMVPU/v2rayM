namespace ServiceLib.Models.Dto;

public class UpdateResult
{
    public bool Success { get; set; }
    public string? Msg { get; set; }
    public SemanticVersion? Version { get; set; }
    public string? Url { get; set; }
    public string? ReleaseTag { get; set; }
    public string? VersionLabel => ReleaseTag ?? Version?.ToString();

    public UpdateResult(bool success, string? msg)
    {
        Success = success;
        Msg = msg;
    }

    public UpdateResult(bool success, SemanticVersion? version)
    {
        Success = success;
        Version = version;
    }
}
