using ServiceLib.Handler;
using ServiceLib.Helper;
using ServiceLib.Manager;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    public async Task<IReadOnlyList<SubscriptionView>> GetSubscriptionsAsync()
    {
        var items = await AppManager.Instance.SubItems() ?? [];
        return items.Select(ToSubscriptionView).ToArray();
    }

    public async Task<SubscriptionMutationResult> AddSubscriptionAsync(SubscriptionInput input)
    {
        if (!TryValidateSubscription(input, out var code, out var messageKey))
        {
            return new(false, code, messageKey, null);
        }

        var item = ToSubItem(input, null);
        var result = await _mutations.RunAsync(() => ConfigHandler.AddSubItem(Config, item));
        if (result != 0)
        {
            return new(false, "subscription_save_failed", ApiMessageKeys.SubscriptionSaveFailed, null);
        }

        var saved = await AppManager.Instance.GetSubItem(item.Id);
        return saved is null
            ? new(false, "subscription_save_failed", ApiMessageKeys.SubscriptionSaveFailed, null)
            : new(true, "ok", ApiMessageKeys.SubscriptionAdded, ToSubscriptionView(saved));
    }

    public async Task<SubscriptionMutationResult> UpdateSubscriptionAsync(string id, SubscriptionInput input)
    {
        if (!TryValidateSubscription(input, out var code, out var messageKey))
        {
            return new(false, code, messageKey, null);
        }

        return await _mutations.RunAsync(async () =>
        {
            var existing = await AppManager.Instance.GetSubItem(id);
            if (existing is null)
            {
                return new SubscriptionMutationResult(false, "subscription_not_found", ApiMessageKeys.SubscriptionNotFound, null);
            }

            var item = ToSubItem(input, existing);
            item.Id = id;
            var result = await ConfigHandler.AddSubItem(Config, item);
            if (result != 0)
            {
                return new SubscriptionMutationResult(false, "subscription_save_failed", ApiMessageKeys.SubscriptionSaveFailed, null);
            }

            var saved = await AppManager.Instance.GetSubItem(id);
            return saved is not null
                ? new SubscriptionMutationResult(true, "ok", ApiMessageKeys.SubscriptionSaved, ToSubscriptionView(saved))
                : new SubscriptionMutationResult(false, "subscription_save_failed", ApiMessageKeys.SubscriptionSaveFailed, null);
        });
    }

    public async Task<OperationView> DeleteSubscriptionAsync(string id)
    {
        var subscription = await AppManager.Instance.GetSubItem(id);
        if (subscription is null)
        {
            return OperationView.Fail("subscription_not_found", ApiMessageKeys.SubscriptionNotFound);
        }

        var selectedProfile = await AppManager.Instance.GetProfileItem(Config.IndexId);
        var removesCurrentProfile = selectedProfile?.Subid == id;
        if (removesCurrentProfile)
        {
            await StopCoreAsync(CancellationToken.None);
        }

        await _mutations.RunAsync(async () =>
        {
            if (await ConfigHandler.DeleteSubItem(Config, id) != 0)
            {
                throw new IOException("ServiceLib could not delete the subscription.");
            }
            if (removesCurrentProfile)
            {
                _ = await ConfigHandler.GetDefaultServer(Config);
                await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
            }
        });

        AddLog("subscription", ApiMessageKeys.SubscriptionDeleted);
        return OperationView.Ok(ApiMessageKeys.SubscriptionDeleted);
    }

    public bool StartSubscriptionUpdate(string id, bool useProxy)
    {
        return StartSubscriptionUpdateTask(id, useProxy, _operations.ShutdownToken) is not null;
    }

    private Task? StartSubscriptionUpdateTask(string id, bool useProxy, CancellationToken operationToken)
    {
        lock (_subscriptionGate)
        {
            var hasConflictingUpdate = _subscriptionTasks.Any(pair =>
                !pair.Value.IsCompleted
                && (pair.Key.Length == 0 || id.Length == 0 || pair.Key == id));
            if (hasConflictingUpdate)
            {
                return null;
            }

            var task = Task.Run(async () =>
            {
                try
                {
                    await using var operation = await _operations.EnterOperationAsync(operationToken);
                    await _mutations.RunAsync(async () =>
                    {
                        await SubscriptionHandler.UpdateProcess(Config, id, useProxy, (success, message) =>
                        {
                            var payload = new
                            {
                                subscriptionId = id,
                                success,
                                code = success ? "ok" : "subscription_update_progress",
                                messageKey = success ? ApiMessageKeys.SubscriptionSaved : ApiMessageKeys.SubscriptionUpdateProgress,
                                rawLog = message,
                            };
                            _events.Publish("subscription-progress", payload);
                            AddLog("subscription", message);
                            return Task.CompletedTask;
                        });

                        operation.Token.ThrowIfCancellationRequested();
                        await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
                        await UpdateSubscriptionTimestampLockedAsync(id);
                    }, operation.Token);
                    _events.Publish("profiles-changed", new { subscriptionId = id });
                }
                catch (OperationCanceledException) when (_operations.IsStopping || operationToken.IsCancellationRequested)
                {
                    // Expected during graceful service shutdown.
                }
                catch (Exception ex)
                {
                    AddLog("subscription", ex.Message);
                }
                finally
                {
                    lock (_subscriptionGate)
                    {
                        _subscriptionTasks.Remove(id);
                    }
                }
            });

            _subscriptionTasks[id] = task;
            return task;
        }
    }

    // The subscription update owns the mutation gate while calling this helper.
    private async Task UpdateSubscriptionTimestampLockedAsync(string subscriptionId)
    {
        var updateTime = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (subscriptionId.Length > 0)
        {
            var item = await AppManager.Instance.GetSubItem(subscriptionId);
            if (item is not null)
            {
                item.UpdateTime = updateTime;
                if (await ConfigHandler.AddSubItem(Config, item) != 0)
                {
                    throw new IOException("ServiceLib could not save the subscription timestamp.");
                }
            }
            return;
        }

        foreach (var item in await AppManager.Instance.SubItems() ?? [])
        {
            if (item.Enabled)
            {
                item.UpdateTime = updateTime;
                if (await ConfigHandler.AddSubItem(Config, item) != 0)
                {
                    throw new IOException("ServiceLib could not save the subscription timestamp.");
                }
            }
        }
    }

    internal static bool TryValidateSubscription(SubscriptionInput input, out string code, out string messageKey)
    {
        if (string.IsNullOrWhiteSpace(input.Remarks))
        {
            code = "subscription_name_required";
            messageKey = ApiMessageKeys.SubscriptionNameRequired;
            return false;
        }
        if (!string.IsNullOrWhiteSpace(input.Url)
            && (!Uri.TryCreate(input.Url, UriKind.Absolute, out var uri)
                || uri.Scheme is not ("http" or "https")))
        {
            code = "subscription_url_invalid";
            messageKey = ApiMessageKeys.SubscriptionInvalidUrl;
            return false;
        }
        if (!HttpRequestHeadersHelper.TryParse(input.RequestHeaders, out _))
        {
            code = "subscription_headers_invalid";
            messageKey = ApiMessageKeys.CommonInvalidInput;
            return false;
        }

        code = "ok";
        messageKey = string.Empty;
        return true;
    }
}
