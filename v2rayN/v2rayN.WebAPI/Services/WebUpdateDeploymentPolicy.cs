using V2rayM.Domain.Updates;

namespace v2rayN.WebAPI.Services;

internal enum WebDeploymentKind
{
    NativeWritable,
    SystemdManaged,
    Container,
    ReadOnly,
    Unsupported,
}

internal sealed record WebUpdateDeployment(WebDeploymentKind Kind, bool CanCheck, bool CanInstall, string? InstallReasonKey);

internal static class WebUpdateDeploymentPolicy
{
    public static WebUpdateDeployment Evaluate(
        bool isSupportedNativePlatform,
        bool isContainer,
        bool isSystemdManaged,
        bool isNativeSingleFile,
        bool installDirectoryWritable)
    {
        var deployment = ApplicationDeploymentPolicy.Evaluate(isSupportedNativePlatform, isContainer,
            isSystemdManaged, isNativeSingleFile, installDirectoryWritable);
        var (kind, reason) = deployment.Kind switch
        {
            ApplicationDeploymentKind.Container => (WebDeploymentKind.Container, "maintenance.webUpdateContainerImage"),
            ApplicationDeploymentKind.SystemdManaged => (WebDeploymentKind.SystemdManaged, "maintenance.webUpdateSystemdAdmin"),
            ApplicationDeploymentKind.ReadOnly => (WebDeploymentKind.ReadOnly, "maintenance.webUpdateReadOnly"),
            ApplicationDeploymentKind.NativeWritable => (WebDeploymentKind.NativeWritable, (string?)null),
            _ => (WebDeploymentKind.Unsupported, "maintenance.webUpdateUnsupported"),
        };
        return new(kind, deployment.CanCheck, deployment.CanInstall && kind != WebDeploymentKind.Unsupported, reason);
    }
}
