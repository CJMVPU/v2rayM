namespace V2rayM.Application.Updates;

internal static class UpdateDiagnostics
{
    public static void Report(Action<string> report, string message)
    {
        try { report(message); }
        catch (Exception)
        {
            // A closed diagnostic sink must not suppress cleanup, replace the
            // original failure, or turn post-commit housekeeping into rollback.
        }
    }
}
