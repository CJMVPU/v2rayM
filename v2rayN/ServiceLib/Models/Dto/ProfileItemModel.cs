namespace ServiceLib.Models.Dto;

[Serializable]
public class ProfileItemModel
{
    public bool IsActive { get; set; }
    public string IndexId { get; set; }
    public EConfigType ConfigType { get; set; }
    public string Remarks { get; set; }
    public string Address { get; set; }
    public int Port { get; set; }
    public string Network { get; set; }
    public string StreamSecurity { get; set; }
    public string Subid { get; set; }
    public string SubRemarks { get; set; }
    public int Sort { get; set; }

    public int Delay { get; set; }

    public decimal Speed { get; set; }

    public string DelayVal { get; set; }

    public string SpeedVal { get; set; }

    public string IpInfo { get; set; }

    public string TodayUp { get; set; }

    public string TodayDown { get; set; }

    public string TotalUp { get; set; }

    public string TotalDown { get; set; }

    public string GetSummary()
    {
        var summary = $"[{ConfigType}] {Remarks}";
        if (!ConfigType.IsComplexType())
        {
            summary += $"({Address}:{Port})";
        }

        return summary;
    }
}
