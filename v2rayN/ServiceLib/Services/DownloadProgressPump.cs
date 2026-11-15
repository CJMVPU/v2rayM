using System.Threading.Channels;

namespace ServiceLib.Services;

/// Adapts the downloader's synchronous events to ordered, awaited async callbacks.
internal static class DownloadProgressPump
{
    public static async Task RunAsync(
        Func<Action<string>, CancellationToken, Task> download,
        Func<string, Task> report,
        CancellationToken cancellationToken)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        // Speed reports are snapshots. Bound pending reports for a slow consumer while
        // retaining the latest/final value; do not accumulate one Task per event.
        var pending = Channel.CreateBounded<string>(new BoundedChannelOptions(16)
        {
            SingleReader = true,
            FullMode = BoundedChannelFullMode.DropOldest,
        });
        var consumer = ConsumeAsync();
        try
        {
            await download(message =>
            {
                lifetime.Token.ThrowIfCancellationRequested();
                pending.Writer.TryWrite(message);
            }, lifetime.Token);
        }
        finally
        {
            pending.Writer.TryComplete();
            // Completion (including cancellation) cannot leave an async callback running.
            await consumer;
        }

        async Task ConsumeAsync()
        {
            try
            {
                await foreach (var message in pending.Reader.ReadAllAsync(lifetime.Token))
                    await report(message);
            }
            catch
            {
                lifetime.Cancel();
                throw;
            }
        }
    }
}
