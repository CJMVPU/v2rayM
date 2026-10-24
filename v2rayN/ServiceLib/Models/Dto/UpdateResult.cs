namespace ServiceLib.Models.Dto;

public enum UpdateCheckDecision { Current, Available, AwaitingValidation, Failed }

public class UpdateResult
{
    public bool Success { get; set; }
    public string? Msg { get; set; }
    public SemanticVersion? Version { get; set; }
    public string? Url { get; set; }
    public UpdateCheckDecision? Decision { get; set; }
    // Retained for the existing API/ServiceLib callers during contract migration.
    public bool AwaitingCompatibilityValidation
    {
        get => Decision == UpdateCheckDecision.AwaitingValidation;
        set { if (value) Decision = UpdateCheckDecision.AwaitingValidation; else if (AwaitingCompatibilityValidation) Decision = null; }
    }
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
