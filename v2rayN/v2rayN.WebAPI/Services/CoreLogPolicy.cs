using System.Text.RegularExpressions;

namespace v2rayN.WebAPI.Services;

internal static partial class CoreLogPolicy
{
    // Drop only the exact known informational probe. Never match errors by substring.
    [GeneratedRegex(@"\A(?:\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}\.\d+ )?\[Info\] \[\d+\] proxy/socks: Connection closed immediately, likely health check connection\z")]
    private static partial Regex HealthCheck();
    internal static bool ShouldKeep(string source, string message) => source != "core" || !HealthCheck().IsMatch(message.TrimEnd());
}
