namespace V2rayM.Domain.Runtime;

public sealed record RuntimeLogEntry(DateTimeOffset Timestamp, string Source, string Message, long Generation, long Sequence);
public sealed record RuntimeLogTail(IReadOnlyList<RuntimeLogEntry> Items, long LatestSequence, long Generation);

/// One host owns one history. Its adapter serializes access and supplies time;
/// connection mode changes never reset history or sequence identity.
public sealed class RuntimeLogHistory
{
    public const int Capacity = 10_000;
    public const int MaximumMessageCharacters = 16 * 1024;
    public const int MaximumRetainedCharacters = 8_000_000;
    private readonly Queue<RuntimeLogEntry> _items = new();
    private int _retainedCharacters;
    private long _generation;
    private long _sequence;

    public RuntimeLogEntry Add(DateTimeOffset timestamp, string source, string message)
    {
        var normalized = message.TrimEnd();
        if (normalized.Length > MaximumMessageCharacters)
        {
            const string marker = "… [log entry truncated]";
            normalized = normalized[..(MaximumMessageCharacters - marker.Length)] + marker;
        }
        var entry = new RuntimeLogEntry(timestamp, source, normalized, _generation, ++_sequence);
        _items.Enqueue(entry);
        _retainedCharacters += entry.Source.Length + entry.Message.Length;
        while (_items.Count > Capacity || _retainedCharacters > MaximumRetainedCharacters)
        {
            var removed = _items.Dequeue();
            _retainedCharacters -= removed.Source.Length + removed.Message.Length;
        }
        return entry;
    }

    public RuntimeLogEntry[] Snapshot() => _items.ToArray();

    public RuntimeLogTail Tail(long afterSequence, int limit)
    {
        // A cursor ahead of this host belongs to an earlier backend session.
        var after = afterSequence > _sequence ? 0 : Math.Max(0, afterSequence);
        if (after == _sequence) return new([], _sequence, _generation);
        var entries = _items.Where(item => item.Sequence > after).TakeLast(Math.Clamp(limit, 1, Capacity)).ToArray();
        return new(entries, _sequence, _generation);
    }

    public long Clear()
    {
        _items.Clear(); _retainedCharacters = 0;
        return ++_generation;
    }
}
