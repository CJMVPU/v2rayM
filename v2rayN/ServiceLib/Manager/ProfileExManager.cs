namespace ServiceLib.Manager;

public class ProfileExManager
{
    private static readonly Lazy<ProfileExManager> _instance = new(() => new());
    public static ProfileExManager Instance => _instance.Value;
    private readonly SQLiteHelper? _database;
    private SQLiteHelper Database => _database ?? SQLiteHelper.Instance;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _saveGate = new(1, 1);
    private Dictionary<string, ProfileExItem> _items = [];
    private readonly Dictionary<string, long> _dirty = [];
    private long _revision;

    public ProfileExManager() : this(null) { }
    public ProfileExManager(SQLiteHelper? database) => _database = database;

    public async Task Init()
    {
        await _saveGate.WaitAsync();
        try
        {
            await Database.ExecuteAsync("delete from ProfileExItem where indexId not in (select indexId from ProfileItem)");
            var loaded = await Database.TableAsync<ProfileExItem>().ToListAsync();
            lock (_gate)
            {
                // Preserve updates that arrived while the database snapshot was loading.
                var merged = loaded.ToDictionary(item => item.IndexId);
                foreach (var id in _dirty.Keys) merged[id] = _items[id];
                _items = merged;
            }
        }
        finally { _saveGate.Release(); }
    }

    public Task<List<ProfileExItem>> GetProfileExs()
    {
        lock (_gate) return Task.FromResult(_items.Values.Select(Clone).ToList());
    }

    public async Task SaveTo()
    {
        await _saveGate.WaitAsync();
        try
        {
            (ProfileExItem Item, long Revision)[] pending;
            lock (_gate)
                pending = _dirty.Select(entry => (Clone(_items[entry.Key]), entry.Value)).ToArray();
            if (pending.Length == 0) return;
            // A failed transaction leaves every dirty revision available for retry.
            await Database.RunInTransactionAsync(db =>
            {
                foreach (var entry in pending) db.InsertOrReplace(entry.Item);
            });
            lock (_gate)
            {
                foreach (var entry in pending)
                    if (_dirty.TryGetValue(entry.Item.IndexId, out var revision) && revision == entry.Revision)
                        _dirty.Remove(entry.Item.IndexId);
            }
        }
        finally { _saveGate.Release(); }
    }

    public async Task ClearAll()
    {
        await _saveGate.WaitAsync();
        try
        {
            long revision;
            lock (_gate) revision = _revision;
            await Database.DeleteAllAsync<ProfileExItem>();
            lock (_gate)
            {
                // Clear the requested snapshot, retaining edits made during the await.
                foreach (var id in _items.Keys.ToArray())
                    if (!_dirty.TryGetValue(id, out var changed) || changed <= revision)
                    {
                        _items.Remove(id);
                        _dirty.Remove(id);
                    }
            }
        }
        finally { _saveGate.Release(); }
    }

    private void Update(string indexId, Action<ProfileExItem> update)
    {
        ArgumentException.ThrowIfNullOrEmpty(indexId);
        lock (_gate)
        {
            if (!_items.TryGetValue(indexId, out var item))
                _items[indexId] = item = new ProfileExItem { IndexId = indexId, Message = string.Empty };
            update(item);
            _dirty[indexId] = ++_revision;
        }
    }

    public void SetTestDelay(string indexId, int delay) => Update(indexId, item => item.Delay = delay);
    public void SetTestSpeed(string indexId, decimal speed) => Update(indexId, item => item.Speed = speed);
    public void SetTestMessage(string indexId, string message) => Update(indexId, item => item.Message = message);
    public void SetTestIpInfo(string indexId, string ipInfo) => Update(indexId, item => item.IpInfo = ipInfo);
    public void SetSort(string indexId, int sort) => Update(indexId, item => item.Sort = sort);
    public int GetSort(string indexId)
    {
        lock (_gate) return _items.GetValueOrDefault(indexId)?.Sort ?? 0;
    }
    public int GetMaxSort()
    {
        lock (_gate) return _items.Count == 0 ? 0 : _items.Values.Max(item => item.Sort);
    }

    private static ProfileExItem Clone(ProfileExItem item) => new()
    {
        IndexId = item.IndexId, Delay = item.Delay, Speed = item.Speed,
        Sort = item.Sort, Message = item.Message, IpInfo = item.IpInfo,
    };
}
