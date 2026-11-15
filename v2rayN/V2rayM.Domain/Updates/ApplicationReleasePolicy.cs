namespace V2rayM.Domain.Updates;

public static class ApplicationReleasePolicy
{
    public static bool Consider(bool isPrerelease, bool allowPrerelease) => !isPrerelease || allowPrerelease;

    // Version syntax and ordering come from the release-format adapter. A same-
    // version rebuild is eligible only when both build identities are known.
    public static bool IsAvailable(int candidateComparedToCurrent, string? currentCommit, string? candidateCommit) =>
        candidateComparedToCurrent > 0 || candidateComparedToCurrent == 0
        && !string.IsNullOrWhiteSpace(currentCommit) && !string.IsNullOrWhiteSpace(candidateCommit)
        && !string.Equals(currentCommit, candidateCommit, StringComparison.OrdinalIgnoreCase);
}

public enum ApplicationDeploymentKind { NativeWritable, SystemdManaged, Container, ReadOnly, Unsupported }
public sealed record ApplicationUpdateDeployment(ApplicationDeploymentKind Kind, bool CanCheck, bool CanInstall);
public static class ApplicationDeploymentPolicy
{
    public static ApplicationUpdateDeployment Evaluate(bool supportedNativePlatform, bool container,
        bool systemdManaged, bool nativeSingleFile, bool writable)
    {
        var kind = container ? ApplicationDeploymentKind.Container
            : systemdManaged ? ApplicationDeploymentKind.SystemdManaged
            : !supportedNativePlatform || !nativeSingleFile ? ApplicationDeploymentKind.Unsupported
            : !writable ? ApplicationDeploymentKind.ReadOnly : ApplicationDeploymentKind.NativeWritable;
        return new(kind, true, kind == ApplicationDeploymentKind.NativeWritable);
    }
}
