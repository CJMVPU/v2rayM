namespace ServiceLib.Manager;

public class NoticeManager
{
    private static readonly Lazy<NoticeManager> _instance = new(() => new());
    public static NoticeManager Instance => _instance.Value;

    public void Enqueue(string? content)
    {
        if (content.IsNullOrEmpty())
        {
            return;
        }
        Logging.SaveLog(content);
    }

    public void SendMessage(string? content)
    {
        if (content.IsNullOrEmpty())
        {
            return;
        }
        Logging.SaveLog(content);
    }

    public void SendMessageEx(string? content)
    {
        if (content.IsNullOrEmpty())
        {
            return;
        }
        content = $"{DateTime.Now:yyyy/MM/dd HH:mm:ss} {content}";
        SendMessage(content);
    }

    public void SendMessageAndEnqueue(string? msg)
    {
        SendMessage(msg);
    }

    /// <summary>
    /// Records each error and warning in <paramref name="validatorResult"/> in the shared log.
    /// Returns <c>true</c> when there were any messages so the caller can decide on early-return
    /// based on <see cref="NodeValidatorResult.Success"/>.
    /// </summary>
    public bool NotifyValidatorResult(NodeValidatorResult validatorResult)
    {
        var msgs = new List<string>([.. validatorResult.Errors, .. validatorResult.Warnings]);
        if (msgs.Count == 0)
        {
            return false;
        }
        foreach (var msg in msgs)
        {
            SendMessage(msg);
        }
        return true;
    }
}
