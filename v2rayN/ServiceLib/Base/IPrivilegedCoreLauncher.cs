namespace ServiceLib.Base;

/// <summary>Optional host-owned elevation adapter. The normal upstream launch path is unchanged.</summary>
public interface IPrivilegedCoreLauncher
{
    Task<ProcessService> StartAsync(CoreInfo coreInfo, string configPath, Func<bool, string, Task>? log);
}
