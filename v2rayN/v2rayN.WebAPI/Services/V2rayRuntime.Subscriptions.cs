using v2rayN.WebAPI.Adapters.Subscriptions;
using V2rayM.Domain.Subscriptions;
using V2rayM.Application.Subscriptions;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    public async Task<IReadOnlyList<SubscriptionView>> GetSubscriptionsAsync() =>
        (await _subscriptions.ListAsync()).Select(SubscriptionContractMapper.ToView).ToArray();

    public async Task<SubscriptionMutationResult> AddSubscriptionAsync(SubscriptionInput input) =>
        SubscriptionContractMapper.ToResult(await _subscriptions.SaveAsync(SubscriptionContractMapper.ToEdit(input)));

    public async Task<SubscriptionMutationResult> UpdateSubscriptionAsync(string id, SubscriptionInput input) =>
        SubscriptionContractMapper.ToResult(await _subscriptions.SaveAsync(SubscriptionContractMapper.ToEdit(input), id));

    public Task<OperationView> DeleteSubscriptionAsync(string id) =>
        _coreLifecycle.ExecuteAsync(async () =>
        {
            OperationView? stop = null;
            var result = await _subscriptionRemoval.DeleteAsync(id, async () =>
            {
                stop = await StopCoreLockedAsync(CancellationToken.None);
                return stop.Success;
            });
            if (result == SubscriptionRemovalResult.NotFound)
                return OperationView.Fail("subscription_not_found", ApiMessageKeys.SubscriptionNotFound);
            if (result == SubscriptionRemovalResult.StopFailed) return stop!;
            AddLog("subscription", ApiMessageKeys.SubscriptionDeleted);
            return OperationView.Ok(ApiMessageKeys.SubscriptionDeleted);
        }, CancellationToken.None);

    public bool StartSubscriptionUpdate(string id, bool useProxy) =>
        StartSubscriptionUpdateTask(id, useProxy, _operations.ShutdownToken) is not null;

    private Task? StartSubscriptionUpdateTask(string id, bool useProxy, CancellationToken operationToken) =>
        _subscriptionUpdates.TryStart(id, useProxy, operationToken);

    public IReadOnlyList<string> GetRunningSubscriptionUpdates() => _subscriptionUpdates.Running();

    internal static bool TryValidateSubscription(SubscriptionInput input, out string code, out string messageKey)
    {
        var validation = Subscription.Validate(SubscriptionContractMapper.ToEdit(input),
            new ServiceLibSubscriptionHeaders().IsValid(input.RequestHeaders));
        if (validation == SubscriptionValidation.Valid) { code = "ok"; messageKey = string.Empty; return true; }
        var result = SubscriptionContractMapper.ToResult(new SubscriptionSaveResult(validation switch
        {
            SubscriptionValidation.NameRequired => SubscriptionSaveStatus.NameRequired,
            SubscriptionValidation.InvalidUrl => SubscriptionSaveStatus.InvalidUrl,
            _ => SubscriptionSaveStatus.InvalidHeaders,
        }));
        code = result.Code; messageKey = result.MessageKey; return false;
    }
}
