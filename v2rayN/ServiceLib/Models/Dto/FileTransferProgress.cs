namespace ServiceLib.Models.Dto;

public sealed record FileTransferProgress(long DownloadedBytes, long? TotalBytes, int CompletedFiles, int TotalFiles)
{
    public static FileTransferProgress FromStates(ReadOnlySpan<FileDownloadState> states)
    {
        long downloaded = 0, total = 0;
        var completed = 0;
        var known = true;
        foreach (var state in states)
        {
            downloaded += Math.Max(0, state.DownloadedBytes);
            total += Math.Max(0, state.TotalBytes);
            if (state.Completed) completed++;
            if (state.TotalBytes <= 0 && !state.Completed) known = false;
        }
        return new(downloaded, known && total > 0 ? total : null, completed, states.Length);
    }
}
