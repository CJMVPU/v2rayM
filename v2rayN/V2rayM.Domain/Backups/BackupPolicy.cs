namespace V2rayM.Domain.Backups;

public static class BackupPolicy
{
    public const long MaximumArchiveBytes = 64L * 1024 * 1024;
    public const long MaximumExpandedBytes = 256L * 1024 * 1024;
    public const int MaximumEntries = 2048;
    public static bool IsValidArchiveSize(long bytes) => bytes > 0 && bytes <= MaximumArchiveBytes;
}

public sealed record WebDavSettings(string? Url, string? UserName, string? Password, string? Directory)
{
    public WebDavSettings Normalize() => this with { Url = Url?.Trim(), UserName = UserName?.Trim(), Directory = Directory?.Trim() };
}
