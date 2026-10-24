using v2rayN.WebAPI.Contracts;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace v2rayN.WebAPI.Services;

public sealed class LogBuffer
{
    public const int Capacity = 10_000;
    private const int MaximumMessageCharacters = 16 * 1024;
    public const int MaximumRetainedCharacters = 8_000_000;
    private readonly object _gate = new();
    private readonly Queue<LogView> _items = new();
    private int _retainedCharacters;
    private long _generation;
    private long _sequence;

    public LogView Add(string source, string message)
    {
        var normalized = message.TrimEnd();
        if (normalized.Length > MaximumMessageCharacters)
        {
            const string marker = "… [log entry truncated]";
            normalized = normalized[..(MaximumMessageCharacters - marker.Length)] + marker;
        }
        LogView entry;
        lock (_gate)
        {
            entry = new LogView(DateTimeOffset.UtcNow, source, normalized, _generation, ++_sequence);
            _items.Enqueue(entry);
            _retainedCharacters += entry.Source.Length + entry.Message.Length;
            while (_items.Count > Capacity || _retainedCharacters > MaximumRetainedCharacters)
            {
                var removed = _items.Dequeue();
                _retainedCharacters -= removed.Source.Length + removed.Message.Length;
            }
        }

        return entry;
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
        lock (_gate) snapshot = _items.ToArray();
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
            // A new backend session has its own sequence. Return its available history
            // if a reconnecting client presents a cursor from the previous session.
            var after = afterSequence > _sequence ? 0 : Math.Max(0, afterSequence);
            var items = _items.Where(item => item.Sequence > after).TakeLast(Math.Clamp(limit, 1, Capacity)).ToArray();
            return new LogTailView(items, _sequence, _generation);
        }
    }

    public long Clear()
    {
        lock (_gate)
        {
            _items.Clear();
            _retainedCharacters = 0;
            return ++_generation;
        }
    }
}
