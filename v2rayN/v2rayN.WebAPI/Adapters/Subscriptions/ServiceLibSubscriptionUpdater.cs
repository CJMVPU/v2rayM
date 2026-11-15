using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using V2rayM.Application.Subscriptions;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Subscriptions;

internal sealed class ServiceLibSubscriptionUpdater(Func<Config> config, Func<Task> save) : ISubscriptionUpdater
{
    public Task UpdateAsync(string id, bool useProxy, Func<bool, string, Task> progress) =>
        SubscriptionHandler.UpdateProcess(config(), id, useProxy, progress);
    public Task SaveConfigurationAsync() => save();
    public async Task StampAsync(string id, long unixTime)
    {
        var items = id.Length == 0
            ? (await ConfigDbQuery.SubItems() ?? []).Where(item => item.Enabled).ToArray()
            : await ConfigDbQuery.GetSubItem(id) is { } selected ? [selected] : [];
        foreach (var item in items)
        {
            item.UpdateTime = unixTime;
            if (await ConfigDbHandler.AddSubItem(config(), item) != 0)
                throw new IOException("ServiceLib could not save the subscription timestamp.");
        }
    }
}

internal sealed class SubscriptionUpdateEvents(Services.EventHub events, Action<string> log) : ISubscriptionUpdateEvents
{
    public Task ProgressAsync(string id, bool success, string message)
    {
        events.Publish("subscription-progress", new
        {
            subscriptionId = id, success, code = success ? "ok" : "subscription_update_progress",
            messageKey = success ? ApiMessageKeys.SubscriptionSaved : ApiMessageKeys.SubscriptionUpdateProgress,
            rawLog = message,
        });
        log(message);
        return Task.CompletedTask;
    }
    public void Changed(string id) => events.Publish("profiles-changed", new { subscriptionId = id });
    public void Failed(Exception exception) => log(exception.Message);
}
