using v2rayN.WebAPI.Contracts;
using V2rayM.Domain.Runtime;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace v2rayN.WebAPI.Services;

public sealed class LogBuffer
{
    public const int Capacity = RuntimeLogHistory.Capacity;
    public const int MaximumRetainedCharacters = RuntimeLogHistory.MaximumRetainedCharacters;
    private readonly object _gate = new();
    private readonly RuntimeLogHistory _history = new();

    private static LogView View(RuntimeLogEntry entry) => new(entry.Timestamp, entry.Source, entry.Message, entry.Generation, entry.Sequence);

    public LogView Add(string source, string message)
    {
        lock (_gate) return View(_history.Add(DateTimeOffset.UtcNow, source, message));
    }

    public IReadOnlyList<LogView> Recent(int limit, string? filter = null) =>
        FilterSnapshot(filter).TakeLast(Math.Clamp(limit, 1, Capacity)).ToArray();

    public LogPageView RecentPage(int page, int pageSize, string? filter = null)
    {
        var items = FilterSnapshot(filter);
        var total = items.Length;
        var safePageSize = Math.Clamp(pageSize, 1, 200);
        var totalPages = Math.Max(1, (total + safePageSize - 1) / safePageSize);
        var safePage = Math.Clamp(page, 1, totalPages);
        var end = total - ((safePage - 1) * safePageSize);
        var start = Math.Max(0, end - safePageSize);
        return new LogPageView(items.Skip(start).Take(end - start).ToArray(), safePage, safePageSize, total, totalPages);
    }

    private LogView[] FilterSnapshot(string? filter)
    {
        LogView[] snapshot;
        lock (_gate) snapshot = _history.Snapshot().Select(View).ToArray();
        if (string.IsNullOrWhiteSpace(filter)) return snapshot;
        // Preserve fail-open search semantics, but abort the entire request's filter
        // on an invalid/expensive pattern instead of retrying it for every log entry.
        if (filter.Length > 4096) return snapshot;
        var watch = Stopwatch.StartNew();
        try
        {
            var regex = new Regex(filter, RegexOptions.None, TimeSpan.FromMilliseconds(50));
            var result = new List<LogView>();
            foreach (var item in snapshot)
            {
                if (watch.Elapsed > TimeSpan.FromMilliseconds(200)) return snapshot;
                if (regex.IsMatch($"{item.Source} {item.Message}")) result.Add(item);
            }
            return result.ToArray();
        }
        catch (ArgumentException) { return snapshot; }
        catch (RegexMatchTimeoutException) { return snapshot; }
    }

    public LogTailView Tail(long afterSequence, int limit)
    {
        lock (_gate)
        {
            var tail = _history.Tail(afterSequence, limit);
            return new(tail.Items.Select(View).ToArray(), tail.LatestSequence, tail.Generation);
        }
    }

    public long Clear()
    {
        lock (_gate) return _history.Clear();
    }
}
