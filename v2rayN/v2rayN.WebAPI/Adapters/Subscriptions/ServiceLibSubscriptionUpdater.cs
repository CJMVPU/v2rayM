using ServiceLib.Handler;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using V2rayM.Application.Subscriptions;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Subscriptions;

internal sealed class ServiceLibSubscriptionUpdater(Func<Config> config, Func<Task> save) : ISubscriptionUpdater
{
    public async Task<IReadOnlyList<SubscriptionUpdateResult>> UpdateAsync(string id, bool useProxy, Func<bool, string, Task> progress) =>
        (await SubscriptionHandler.UpdateProcessWithResults(config(), id, useProxy, progress))
            .Select(value => new SubscriptionUpdateResult(value.Id, value.Kind switch
            {
                ServiceLib.Models.Dto.SubscriptionUpdateOutcomeKind.Succeeded => SubscriptionUpdateStatus.Succeeded,
                ServiceLib.Models.Dto.SubscriptionUpdateOutcomeKind.Failed => SubscriptionUpdateStatus.Failed,
                _ => SubscriptionUpdateStatus.Skipped,
            })).ToArray();
    public Task SaveConfigurationAsync() => save();
    public async Task StampAsync(string id, long unixTime)
    {
        var item = await ConfigDbQuery.GetSubItem(id);
        if (item is null) return;
        item.UpdateTime = unixTime;
        if (await ConfigDbHandler.AddSubItem(config(), item) != 0)
            throw new IOException("ServiceLib could not save the subscription timestamp.");
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
