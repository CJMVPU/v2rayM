namespace ServiceLib.Manager;

public class StatisticsManager
{
    private static readonly Lazy<StatisticsManager> instance = new(() => new());
    public static StatisticsManager Instance => instance.Value;
    private readonly SQLiteHelper? _database;
    private SQLiteHelper Database => _database ?? SQLiteHelper.Instance;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _saveGate = new(1, 1);
    private Config _config;
    private List<ServerStatItem> _lstServerStat = [];
    private Func<ServerSpeedItem, Task>? _updateFunc;
    private StatisticsXrayService? _statisticsXray;
    private bool _initialized;

    public StatisticsManager() : this(null) { }
    public StatisticsManager(SQLiteHelper? database) => _database = database;
    public List<ServerStatItem> ServerStat
    {
        get { lock (_gate) return _lstServerStat.Select(Clone).ToList(); }
    }

    public async Task Init(Config config, Func<ServerSpeedItem, Task> updateFunc)
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            await StopSamplerAsync();
            if (_initialized) await SaveTo();
            _config = config;
            _updateFunc = updateFunc;
            if (config.GuiItem.EnableStatistics || config.GuiItem.DisplayRealTimeSpeed)
            {
                await InitData();
                _initialized = true;
                _statisticsXray = new StatisticsXrayService(config, UpdateServerStat);
                await _statisticsXray.StartAsync();
            }
        }
        finally { _lifecycleGate.Release(); }
    }

    public void ResetSample() => _statisticsXray?.ResetSample();

    public async Task CloseAsync()
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            await StopSamplerAsync();
            if (_initialized) await SaveTo();
        }
        finally { _lifecycleGate.Release(); }
    }

    private async Task StopSamplerAsync()
    {
        if (_statisticsXray is not { } sampler) return;
        await sampler.CloseAsync();
        _statisticsXray = null;
    }

    public async Task ClearAllServerStatistics()
    {
        await _saveGate.WaitAsync();
        try
        {
            await Database.DeleteAllAsync<ServerStatItem>();
            lock (_gate) _lstServerStat = [];
        }
        finally { _saveGate.Release(); }
    }

    public async Task SaveTo()
    {
        await _saveGate.WaitAsync();
        try
        {
            var snapshot = ServerStat;
            if (snapshot.Count == 0) return;
            await Database.RunInTransactionAsync(db =>
            {
                foreach (var item in snapshot) db.InsertOrReplace(item);
            });
        }
        finally { _saveGate.Release(); }
    }

    public async Task CloneServerStatItem(string indexId, string toIndexId)
    {
        if (indexId == toIndexId) return;
        lock (_gate)
        {
            var stat = _lstServerStat.FirstOrDefault(item => item.IndexId == indexId);
            if (stat is null) return;
            var clone = Clone(stat);
            clone.IndexId = toIndexId;
            _lstServerStat.RemoveAll(item => item.IndexId == toIndexId);
            _lstServerStat.Add(clone);
        }
        await SaveTo();
    }

    private async Task InitData()
    {
        await _saveGate.WaitAsync();
        try
        {
            await Database.ExecuteAsync("delete from ServerStatItem where indexId not in (select indexId from ProfileItem)");
            var ticks = DateTime.Now.Date.Ticks;
            await Database.ExecuteAsync("update ServerStatItem set todayUp = 0,todayDown=0,dateNow=? where dateNow<>?", ticks, ticks);
            var loaded = await Database.TableAsync<ServerStatItem>().ToListAsync();
            lock (_gate) _lstServerStat = loaded;
        }
        finally { _saveGate.Release(); }
    }

    private Task UpdateServerStat(ServerSpeedItem server)
    {
        lock (_gate)
        {
            server.IndexId = _config.IndexId;
            if (_config.GuiItem.EnableStatistics)
            {
                var ticks = DateTime.Now.Date.Ticks;
                var stat = _lstServerStat.FirstOrDefault(item => item.IndexId == server.IndexId);
                if (stat is null)
                {
                    stat = new ServerStatItem { IndexId = server.IndexId, DateNow = ticks };
                    _lstServerStat.Add(stat);
                }
                if (stat.DateNow != ticks)
                {
                    stat.TodayUp = 0; stat.TodayDown = 0; stat.DateNow = ticks;
                }
                stat.TodayUp += server.ProxyUp; stat.TodayDown += server.ProxyDown;
                stat.TotalUp += server.ProxyUp; stat.TotalDown += server.ProxyDown;
                server.TodayUp = stat.TodayUp; server.TodayDown = stat.TodayDown;
                server.TotalUp = stat.TotalUp; server.TotalDown = stat.TotalDown;
            }
        }
        return _updateFunc?.Invoke(server) ?? Task.CompletedTask;
    }

    private static ServerStatItem Clone(ServerStatItem item) => new()
    {
        IndexId = item.IndexId, DateNow = item.DateNow, TodayUp = item.TodayUp,
        TodayDown = item.TodayDown, TotalUp = item.TotalUp, TotalDown = item.TotalDown,
    };
}
