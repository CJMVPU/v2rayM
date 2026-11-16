namespace ServiceLib.Handler.Data;

/// Text configuration storage. Callers explicitly pass the configuration owned
/// by their transaction; a rollback snapshot must never be replaced by global state.
public static class ConfigTextHandler
{
    private static readonly string _configRes = Global.ConfigFileName;
    private static readonly string _tag = "ConfigTextHandler";
    public static Config Config => ConfigState.Instance.Current;

    public static bool Init()
    {
        var config = LoadConfig();
        if (config is null) return false;
        ConfigState.Instance.SetCurrent(config);
        return true;
    }

    /// <summary>
    /// Load the application configuration file
    /// If the file exists, deserialize it from JSON
    /// If not found, create a new Config object with default settings
    /// Initialize default values for missing configuration sections
    /// </summary>
    /// <returns>Config object containing application settings or null if there's an error</returns>
    public static Config? LoadConfig(string? configPath = null)
    {
        configPath ??= Utils.GetConfigPath(_configRes);
        Config? config = null;
        var result = EmbedUtils.LoadResource(configPath);
        if (result.IsNotEmpty())
        {
            config = JsonUtils.Deserialize<Config>(result);
            if (config is null)
            {
                // Existing, invalid data is not a first launch. Never allow the
                // host's startup save to replace it with generated defaults.
                Logging.SaveLog("Could not parse the existing configuration; original file retained.");
                return null;
            }
        }
        else
        {
            if (File.Exists(configPath))
            {
                Logging.SaveLog("LoadConfig Exception");
                return null;
            }
        }

        config ??= new Config();

        config.CoreBasicItem ??= new()
        {
            LogEnabled = false,
            Loglevel = "warning",
        };

        if (config.Inbound == null)
        {
            config.Inbound = [];
            InItem inItem = new()
            {
                Protocol = nameof(EInboundProtocol.socks),
                LocalPort = 10808,
                UdpEnabled = true,
                SniffingEnabled = true,
                RouteOnly = false,
            };

            config.Inbound.Add(inItem);
        }
        else
        {
            if (config.Inbound.Count > 0)
            {
                config.Inbound.First().Protocol = nameof(EInboundProtocol.socks);
            }
        }

        config.RoutingBasicItem ??= new();
        if (config.RoutingBasicItem.DomainStrategy.IsNullOrEmpty())
        {
            config.RoutingBasicItem.DomainStrategy = Global.DomainStrategies.First();
        }

        config.KcpItem ??= new KcpItem
        {
            Mtu = 1350,
            Tti = 50,
            UplinkCapacity = 12,
            DownlinkCapacity = 100,
            CwndMultiplier = 1,
            MaxSendingWindow = 2 * 1024 * 1024,
        };
        config.KcpItem.CwndMultiplier = config.KcpItem.CwndMultiplier <= 0 ? 1 : config.KcpItem.CwndMultiplier;
        config.KcpItem.MaxSendingWindow = config.KcpItem.MaxSendingWindow <= 0 ? (2 * 1024 * 1024) : config.KcpItem.MaxSendingWindow;
        config.GrpcItem ??= new GrpcItem
        {
            IdleTimeout = 60,
            HealthCheckTimeout = 20,
            PermitWithoutStream = false,
            InitialWindowsSize = 0,
        };
        config.TunModeItem ??= new TunModeItem
        {
            EnableTun = false,
            Mtu = 9000,
            IcmpRouting = Global.TunIcmpRoutingPolicies.First(),
        };
        config.GuiItem ??= new();
        if (!Global.RootCertProviders.Contains(config.GuiItem.RootCertProvider))
        {
            config.GuiItem.RootCertProvider = Global.RootCertProviders.First();
        }
        config.MsgUIItem ??= new();

        config.UiItem ??= new();
        config.UiItem.MainColumnItem ??= [];
        config.UiItem.WindowSizeItem ??= [];

        if (config.UiItem.CurrentLanguage.IsNullOrEmpty())
        {
            config.UiItem.CurrentLanguage = Thread.CurrentThread.CurrentCulture.TwoLetterISOLanguageName.Equals("zh", StringComparison.CurrentCultureIgnoreCase)
                ? Global.Languages.First()
                : Global.Languages[2];
        }

        config.ConstItem ??= new ConstItem();

        config.SimpleDNSItem ??= ConfigDbHandler.InitBuiltinSimpleDNS();
        config.SimpleDNSItem.BlockAAAAQuery ??= false;
        config.SimpleDNSItem.FakeIPRange ??= Global.FakeIPRanges.FirstOrDefault();
        config.SimpleDNSItem.GlobalFakeIp ??= true;
        config.SimpleDNSItem.BootstrapDNS ??= Global.DomainPureIPDNSAddress.FirstOrDefault();
        config.SimpleDNSItem.ServeStale ??= false;
        config.SimpleDNSItem.ParallelQuery ??= false;
        config.SimpleDNSItem.EnableHappyEyeballs ??= false;

        config.SpeedTestItem ??= new();
        if (config.SpeedTestItem.SpeedTestTimeout < 10)
        {
            config.SpeedTestItem.SpeedTestTimeout = 10;
        }
        if (config.SpeedTestItem.SpeedTestUrl.IsNullOrEmpty())
        {
            config.SpeedTestItem.SpeedTestUrl = Global.SpeedTestUrls.First();
        }
        if (config.SpeedTestItem.SpeedPingTestUrl.IsNullOrEmpty())
        {
            config.SpeedTestItem.SpeedPingTestUrl = Global.SpeedPingTestUrls.First();
        }
        config.SpeedTestItem.MixedConcurrencyCount = Math.Max(config.SpeedTestItem.MixedConcurrencyCount, Global.SpeedTestConcurrencyCountMin);
        if (config.SpeedTestItem.UdpTestTarget.IsNullOrEmpty())
        {
            config.SpeedTestItem.UdpTestTarget = Global.UdpTestTargets.First();
        }

        config.Mux4RayItem ??= new()
        {
            Concurrency = 8,
            XudpConcurrency = 16,
            XudpProxyUDP443 = "reject"
        };

        config.HysteriaItem ??= new()
        {
            UpMbps = 100,
            DownMbps = 100
        };
        config.ClashUIItem ??= new();
        config.ClashUIItem.ConnectionsColumnItem ??= [];
        config.SystemProxyItem ??= new();
        config.WebDavItem ??= new();
        config.CheckUpdateItem ??= new();
        config.Fragment4RayItem ??= new()
        {
            Packets = "tlshello",
        };
        config.Fragment4RayItem.MaxSplit ??= "0";

        config.HappyEyeballs4RayItem ??= new()
        {
            TryDelayMs = 250,
            PrioritizeIPv6 = false,
            Interleave = 1,
            MaxConcurrentTry = 4,
        };
        if ((config.Fragment4RayItem.Lengths ?? []).Count == 0)
        {
            config.Fragment4RayItem.Lengths = [config.Fragment4RayItem.Length ?? "50-100"];
        }
        if ((config.Fragment4RayItem.Delays ?? []).Count == 0)
        {
            config.Fragment4RayItem.Delays = [config.Fragment4RayItem.Interval ?? "10-20"];
        }
        config.GlobalHotkeys ??= [];

        if (config.SystemProxyItem.SystemProxyExceptions.IsNullOrEmpty())
        {
            config.SystemProxyItem.SystemProxyExceptions = Utils.IsWindows() ? Global.SystemProxyExceptionsWindows : Global.SystemProxyExceptionsLinux;
        }

        return config;
    }

    /// <summary>
    /// Save the configuration to a file
    /// First writes to a temporary file, then replaces the original file
    /// </summary>
    /// <param name="config">Configuration object to be saved</param>
    /// <returns>0 if successful, -1 if failed</returns>
    public static async Task<int> SaveConfig(Config config)
    {
        try
        {
            //save temp file
            var resPath = Utils.GetConfigPath(_configRes);
            var tempPath = $"{resPath}_temp";

            var content = JsonUtils.Serialize(config, true, true);
            if (content.IsNullOrEmpty())
            {
                return -1;
            }
            await File.WriteAllTextAsync(tempPath, content);

            //rename
            File.Move(tempPath, resPath, true);
        }
        catch (Exception ex)
        {
            Logging.SaveLog(_tag, ex);
            return -1;
        }

        return 0;
    }

    /// <summary>
    /// Set the default server by its index ID
    /// Updates the configuration to use the specified server as default
    /// </summary>
    /// <param name="config">Current configuration</param>
    /// <param name="indexId">Index ID of the server to set as default</param>
    /// <returns>0 if successful, -1 if failed</returns>
    public static async Task<int> SetDefaultServerIndex(Config config, string? indexId)
    {
        if (indexId.IsNullOrEmpty())
        {
            return -1;
        }

        config.IndexId = indexId;

        await SaveConfig(config);

        return 0;
    }

    /// <summary>
    /// Set a default server from the provided list of profiles
    /// Ensures there's always a valid default server selected
    /// </summary>
    /// <param name="config">Current configuration</param>
    /// <param name="lstProfile">List of profile models to choose from</param>
    /// <returns>Result of SetDefaultServerIndex operation</returns>
    public static async Task<int> SetDefaultServer(Config config, List<ProfileItemModel> lstProfile)
    {
        if (lstProfile.Exists(t => t.IndexId == config.IndexId))
        {
            return 0;
        }

        if (await SQLiteHelper.Instance.TableAsync<ProfileItem>().FirstOrDefaultAsync(t => t.IndexId == config.IndexId) != null)
        {
            return 0;
        }
        if (lstProfile.Count > 0)
        {
            return await SetDefaultServerIndex(config, lstProfile.FirstOrDefault(t => t.Port > 0)?.IndexId);
        }

        var item = await SQLiteHelper.Instance.TableAsync<ProfileItem>().FirstOrDefaultAsync(t => t.Port > 0);
        return await SetDefaultServerIndex(config, item?.IndexId);
    }

    /// <summary>
    /// Get the current default server profile
    /// If the current default is invalid, selects a new default
    /// </summary>
    /// <param name="config">Current configuration</param>
    /// <returns>The default profile item or null if none exists</returns>
    public static async Task<ProfileItem?> GetDefaultServer(Config config)
    {
        var item = await ConfigDbQuery.GetProfileItem(config.IndexId);
        if (item is null)
        {
            var item2 = await SQLiteHelper.Instance.TableAsync<ProfileItem>().FirstOrDefaultAsync();
            await SetDefaultServerIndex(config, item2?.IndexId);
            return item2;
        }

        return item;
    }

    public static WindowSizeItem? GetWindowSizeItem(Config config, string typeName)
    {
        var sizeItem = config?.UiItem?.WindowSizeItem?.FirstOrDefault(t => t.TypeName == typeName);
        if (sizeItem == null || sizeItem.Width <= 0 || sizeItem.Height <= 0)
        {
            return null;
        }

        return sizeItem;
    }

    public static int SaveWindowSizeItem(Config config, string typeName, double width, double height)
    {
        var sizeItem = config?.UiItem?.WindowSizeItem?.FirstOrDefault(t => t.TypeName == typeName);
        if (sizeItem == null)
        {
            sizeItem = new WindowSizeItem { TypeName = typeName };
            config.UiItem.WindowSizeItem.Add(sizeItem);
        }

        sizeItem.Width = (int)width;
        sizeItem.Height = (int)height;

        return 0;
    }

    public static int SaveMainGirdHeight(Config config, double height1, double height2)
    {
        var uiItem = config.UiItem ?? new();

        uiItem.MainGirdHeight1 = (int)(height1 + 0.1);
        uiItem.MainGirdHeight2 = (int)(height2 + 0.1);

        return 0;
    }
}
