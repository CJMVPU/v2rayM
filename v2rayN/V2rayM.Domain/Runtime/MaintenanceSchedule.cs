namespace V2rayM.Domain.Runtime;

public enum MaintenanceAction { Subscriptions, SaveState, CleanupFiles, GeoUpdate, CoreUpdateCheck }

public static class MaintenanceSchedule
{
    // Elapsed scheduler ticks preserve existing cadence; this is intentionally
    // not wall-clock catch-up after sleep or a long-running update.
    public static IReadOnlyList<MaintenanceAction> Due(long elapsedMinutes, int geoIntervalHours)
    {
        if (elapsedMinutes <= 0) throw new ArgumentOutOfRangeException(nameof(elapsedMinutes));
        var actions = new List<MaintenanceAction> { MaintenanceAction.Subscriptions };
        if (elapsedMinutes % 20 == 0) actions.Add(MaintenanceAction.SaveState);
        if (elapsedMinutes % 60 == 0)
        {
            actions.Add(MaintenanceAction.CleanupFiles);
            if (geoIntervalHours > 0 && elapsedMinutes / 60 % geoIntervalHours == 0)
                actions.Add(MaintenanceAction.GeoUpdate);
        }
        if (elapsedMinutes % 1440 == 1) actions.Add(MaintenanceAction.CoreUpdateCheck);
        return actions;
    }
}
