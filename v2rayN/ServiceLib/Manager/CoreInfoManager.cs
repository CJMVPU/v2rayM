namespace ServiceLib.Manager;

public sealed class CoreInfoManager
{
    private static readonly Lazy<CoreInfoManager> _instance = new(() => new());
    private List<CoreInfo>? _coreInfo;
    public static CoreInfoManager Instance => _instance.Value;

    public CoreInfoManager()
    {
        InitCoreInfo();
    }

    public CoreInfo? GetCoreInfo(ECoreType coreType)
    {
        if (_coreInfo == null)
        {
            InitCoreInfo();
        }
        return _coreInfo?.FirstOrDefault(t => t.CoreType == coreType);
    }

    public List<CoreInfo> GetCoreInfo()
    {
        if (_coreInfo == null)
        {
            InitCoreInfo();
        }
        return _coreInfo ?? [];
    }

    public string GetCoreExecFile(CoreInfo? coreInfo, out string msg)
    {
        var fileName = string.Empty;
        msg = string.Empty;
        foreach (var name in coreInfo?.CoreExes ?? [])
        {
            var vName = Utils.GetBinPath(Utils.GetExeName(name), coreInfo.CoreType.ToString());
            if (File.Exists(vName))
            {
                fileName = vName;
                break;
            }
        }
        if (fileName.IsNullOrEmpty())
        {
            msg = string.Format(ResUI.NotFoundCore, Utils.GetBinPath("", coreInfo?.CoreType.ToString()), coreInfo?.CoreExes?.LastOrDefault(), coreInfo?.Url);
            Logging.SaveLog(msg);
        }
        return fileName;
    }

    public List<ECoreType> GetCheckUpdateCoreTypes()
    {
        var lst = new List<ECoreType>();

        if (RuntimeInformation.ProcessArchitecture != Architecture.X86)
        {
            if (IsCheckUpdateSupported(ECoreType.v2rayN))
            {
                lst.Add(ECoreType.v2rayN);
            }

            if (!(Utils.IsWindows() && Environment.OSVersion.Version.Major < 10))
            {
                lst.Add(ECoreType.Xray);
            }
        }

        return lst;
    }

    public bool IsCheckUpdateSupported(ECoreType type)
    {
        return type switch
        {
            ECoreType.v2rayN => !Utils.IsPackagedInstall(),
            ECoreType.Xray => true,
            _ => false,
        };
    }

    public bool GetCheckPreRelease(ECoreType type, bool preRelease)
    {
        return type switch
        {
            ECoreType.v2rayN => preRelease,
            ECoreType.Xray => preRelease,
            _ => false,
        };
    }

    private void InitCoreInfo()
    {
        var urlN = GetCoreUrl(ECoreType.v2rayN);
        var urlXray = GetCoreUrl(ECoreType.Xray);

        _coreInfo =
        [
            new CoreInfo
                {
                    CoreType = ECoreType.v2rayN,
                    Url = GetCoreUrl(ECoreType.v2rayN),
                    ReleaseApiUrl = urlN.Replace(Global.GithubUrl, Global.GithubApiUrl),
                    DownloadUrlWin64 = urlN + "/download/{0}/v2rayN-windows-64.zip",
                    DownloadUrlWinArm64 = urlN + "/download/{0}/v2rayN-windows-arm64.zip",
                    DownloadUrlLinux64 = urlN + "/download/{0}/v2rayN-linux-64.zip",
                    DownloadUrlLinuxArm64 = urlN + "/download/{0}/v2rayN-linux-arm64.zip",
                    DownloadUrlLinuxRiscV64 = urlN + "/download/{0}/v2rayN-linux-riscv64.zip",
                    DownloadUrlLinuxLoong64 = urlN + "/download/{0}/v2rayN-linux-loong64.zip",
                    DownloadUrlOSX64 = urlN + "/download/{0}/v2rayN-macos-64.zip",
                    DownloadUrlOSXArm64 = urlN + "/download/{0}/v2rayN-macos-arm64.zip",
                },





                new CoreInfo
                {
                    CoreType = ECoreType.Xray,
                    CoreExes = ["xray"],
                    Arguments = "run -c {0}",
                    Url = GetCoreUrl(ECoreType.Xray),
                    ReleaseApiUrl = urlXray.Replace(Global.GithubUrl, Global.GithubApiUrl),
                    DownloadUrlWin64 = urlXray + "/download/{0}/Xray-windows-64.zip",
                    DownloadUrlWinArm64 = urlXray + "/download/{0}/Xray-windows-arm64-v8a.zip",
                    DownloadUrlLinux64 = urlXray + "/download/{0}/Xray-linux-64.zip",
                    DownloadUrlLinuxArm64 = urlXray + "/download/{0}/Xray-linux-arm64-v8a.zip",
                    DownloadUrlLinuxRiscV64 = urlXray + "/download/{0}/Xray-linux-riscv64.zip",
                    DownloadUrlLinuxLoong64 = urlXray + "/download/{0}/Xray-linux-loong64.zip",
                    DownloadUrlOSX64 = urlXray + "/download/{0}/Xray-macos-64.zip",
                    DownloadUrlOSXArm64 = urlXray + "/download/{0}/Xray-macos-arm64-v8a.zip",
                    Match = "Xray",
                    VersionArg = "-version",
                    Environment = new Dictionary<string, string?>()
                    {
                        { Global.XrayLocalAsset, Utils.GetBinPath("") },
                        { Global.XrayLocalCert, Utils.GetBinPath("") },
                    },
                },






















        ];
    }


    private static string GetCoreUrl(ECoreType eCoreType)
    {
        return $"{Global.GithubUrl}/{Global.CoreUrls[eCoreType]}/releases";
    }

}
