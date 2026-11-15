namespace V2rayM.Domain.Profiles;

public static class ProfileCleanupPolicy
{
    public static bool CanRemove(bool supported, bool complex, bool selectedOrRunning) =>
        supported && !complex && !selectedOrRunning;
}
