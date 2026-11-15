namespace v2rayN.WebAPI.Services;

internal static class ShutdownDiagnostics
{
    private static string? _currentStage;

    public static string? CurrentStage => Volatile.Read(ref _currentStage);

    public static void SetStage(string? stage) => Volatile.Write(ref _currentStage, stage);
}
