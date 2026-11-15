namespace ServiceLib.Manager;

public sealed class AppManager
{
    #region Property

    private static readonly Lazy<AppManager> _instance = new(() => new());
    private static Config CurrentConfig => ConfigState.Instance.Current;
    private int? _statePort;
    public static AppManager Instance => _instance.Value;

    public int StatePort
    {
        get
        {
            _statePort ??= Utils.GetFreePort(GetLocalPort(EInboundProtocol.api));
            return _statePort.Value;
        }
    }

    public string LinuxSudoPwd { get; set; }

    public bool ShowInTaskbar { get; set; }

    public ECoreType RunningCoreType { get; set; }

    public bool IsRunningCore(ECoreType type)
    {
        switch (type)
        {
            case ECoreType.Xray when RunningCoreType is ECoreType.Xray or ECoreType.v2fly or ECoreType.v2fly_v5:
                return true;

            default:
                return false;
        }
    }

    public Dictionary<ECoreType, string> LastCheckUpdateResults { get; set; } = new();

    public void SetLastCheckUpdateResult(ECoreType coreType, string result)
    {
        LastCheckUpdateResults[coreType] = result;
    }

    #endregion Property

    #region App

    public bool InitApp()
    {
        if (Utils.HasWritePermission() == false)
        {
            Environment.SetEnvironmentVariable(Global.LocalAppData, "1", EnvironmentVariableTarget.Process);
        }

        Logging.Setup();
        if (!ConfigTextHandler.Init())
        {
            return false;
        }
        Thread.CurrentThread.CurrentUICulture = new(CurrentConfig.UiItem.CurrentLanguage);

        //Under Win10
        if (Utils.IsWindows() && Environment.OSVersion.Version.Major < 10)
        {
            Environment.SetEnvironmentVariable("DOTNET_EnableWriteXorExecute", "0", EnvironmentVariableTarget.User);
        }

        SQLiteHelper.Instance.CreateTable<SubItem>();
        SQLiteHelper.Instance.CreateTable<ProfileItem>();
        SQLiteHelper.Instance.CreateTable<ServerStatItem>();
        SQLiteHelper.Instance.CreateTable<RoutingItem>();
        SQLiteHelper.Instance.CreateTable<ProfileExItem>();
        SQLiteHelper.Instance.CreateTable<DNSItem>();
        SQLiteHelper.Instance.CreateTable<FullConfigTemplateItem>();
#pragma warning disable CS0618
        SQLiteHelper.Instance.CreateTable<ProfileGroupItem>();
#pragma warning restore CS0618
        return true;
    }

    public bool InitComponents()
    {
        Logging.SaveLog($"v2rayN start up | {Utils.GetRuntimeInfo()}");
        Logging.LoggingEnabled(CurrentConfig.GuiItem.EnableLog);

        //First determine the port value
        _ = StatePort;

        Task.Run(async () =>
        {
            await ConfigDbHandler.MigrateProfileExtra(CurrentConfig);
        }).Wait();

        return true;
    }

    public bool Reset()
    {
        _statePort = null;
        return true;
    }

    #endregion App

    #region Config

    public int GetLocalPort(EInboundProtocol protocol)
    {
        var localPort = CurrentConfig.Inbound.FirstOrDefault(t => t.Protocol == nameof(EInboundProtocol.socks))?.LocalPort ?? 10808;
        return localPort + (int)protocol;
    }

    #endregion Config

    #region Core Type

    public List<string> GetShadowsocksSecurities(ProfileItem profileItem) => Global.SsSecuritiesInXray;

    public ECoreType GetCoreType(ProfileItem? profileItem, EConfigType eConfigType)
    {
        if (profileItem?.CoreType != null)
        {
            return (ECoreType)profileItem.CoreType;
        }

        return ECoreType.Xray;
    }

    #endregion Core Type
}
