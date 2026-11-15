using V2rayM.Application.Profiles;
using V2rayM.Domain.Profiles;
using v2rayN.WebAPI.Adapters.Profiles;
using ServiceLib.Enums;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed partial class V2rayRuntime
{
    public async Task<IReadOnlyList<ProfileGroupView>> GetProfileGroupsAsync() =>
        (await _profileQueries.GroupsAsync()).Select(group => new ProfileGroupView(group.Id, group.All ? "all" : "subscription",
            group.Name, group.All ? ApiMessageKeys.ProfilesAllGroup : null, group.Count, group.Selected)).ToArray();

    public async Task<OperationView> SelectProfileGroupAsync(string? subscriptionId)
    {
        var result = await _profileCatalog.SelectGroupAsync(subscriptionId);
        return result.Status == ProfileCatalogStatus.Completed
            ? OperationView.Ok(ApiMessageKeys.CommonCompleted, new { subscriptionId = result.GroupId })
            : ProfileCatalogContractMapper.Failure(result);
    }

    public async Task<OperationView> ImportProfilesAsync(ProfileImportRequest request)
    {
        var result = await _profileCatalog.ImportAsync(request.Content, request.SubscriptionId, request.IsSubscription);
        return result.Status == ProfileCatalogStatus.Completed
            ? OperationView.Ok(ApiMessageKeys.ProfileImported, new { imported = result.Count })
            : ProfileCatalogContractMapper.Failure(result, new { imported = result.Count });
    }

    public Task<OperationView> SaveProfileAsync(ProfileItem profile, string? profileId = null)
    {
        if (profile is null) return Task.FromResult(OperationView.Fail("profile_data_required", ApiMessageKeys.CommonInvalidInput));
        return _coreLifecycle.ExecuteAsync(async () =>
        {
            OperationView? restart = null;
            var result = await _profileEditor.SaveAsync(new ServiceLibProfileEditSession(profile, () => Config), profileId,
                async () => { restart = await RestartCoreLockedAsync(CancellationToken.None); return restart.Success; });
            if (result.Error is { } error) AddLog("profile", $"Profile save failed for {profile.ConfigType} ({profile.IndexId}): {error}");
            if (result.Status == ProfileSaveStatus.Rejected)
                AddLog("profile", $"ServiceLib rejected profile save for {profile.ConfigType} ({profile.IndexId}); result={result.PersistenceCode}.");
            return ProfileEditorContractMapper.Result(result, restart?.Code);
        }, CancellationToken.None);
    }

    internal static bool TryValidateProfile(ProfileItem profile, out string code, out string messageKey)
    {
        var validation = ProfileEditing.ValidateSimple(ServiceLibProfileEditSession.Describe(profile));
        (code, messageKey) = ProfileEditorContractMapper.Validation(validation);
        return validation == ProfileValidation.Valid;
    }

    internal static bool IsConfigTypeUnchanged(ProfileItem input, ProfileItem existing) =>
        input.ConfigType == existing.ConfigType;

    public Task<OperationView> DeleteProfilesAsync(IEnumerable<string> profileIds) =>
        _coreLifecycle.ExecuteAsync(async () =>
        {
            OperationView? coreResult = null;
            var result = await _profileRemoval.DeleteAsync(profileIds,
                async () => { coreResult = await StopCoreLockedAsync(CancellationToken.None); return coreResult.Success; },
                async () => { coreResult = await StartCoreLockedAsync(null, CancellationToken.None); return coreResult.Success; });
            return result.Status switch
            {
                ProfileRemovalStatus.SelectionRequired => OperationView.Fail("profile_selection_required", ApiMessageKeys.ProfileSelectRequired),
                ProfileRemovalStatus.NotFound => OperationView.Fail("profile_not_found", ApiMessageKeys.ProfileNotFound),
                ProfileRemovalStatus.StopFailed => coreResult!,
                ProfileRemovalStatus.RestartFailed => OperationView.Fail("profiles_deleted_core_restart_failed", ApiMessageKeys.ProfileDeleted,
                    new { deleted = result.Count, coreRestartRequired = true, coreResultCode = coreResult!.Code }),
                _ => OperationView.Ok(ApiMessageKeys.ProfileDeleted, result.Restarted
                    ? new { deleted = result.Count, coreRestarted = true } : (object)new { deleted = result.Count }),
            };
        }, CancellationToken.None);

    public async Task<OperationView> CopyProfilesAsync(IEnumerable<string> profileIds)
    {
        var result = await _profileCatalog.CopyAsync(profileIds);
        return result.Status == ProfileCatalogStatus.Completed
            ? OperationView.Ok(ApiMessageKeys.ProfileCopied, new { copied = result.Count })
            : ProfileCatalogContractMapper.Failure(result);
    }

    public async Task<OperationView> MoveProfilesToGroupAsync(MoveProfilesRequest request)
    {
        var result = await _profileCatalog.MoveToGroupAsync(request.ProfileIds, request.SubscriptionId);
        return result.Status == ProfileCatalogStatus.Completed
            ? OperationView.Ok(ApiMessageKeys.ProfileMoved, new { moved = result.Count, subscriptionId = result.GroupId })
            : ProfileCatalogContractMapper.Failure(result);
    }

    public async Task<OperationView> MoveProfileAsync(MoveProfileRequest request)
    {
        var direction = request.Direction switch
        {
            EMove.Top => ProfileMove.Top, EMove.Up => ProfileMove.Up, EMove.Down => ProfileMove.Down,
            EMove.Bottom => ProfileMove.Bottom, EMove.Position => ProfileMove.Position,
            _ => (ProfileMove?)null,
        };
        if (direction is null) return OperationView.Fail("profile_order_failed", ApiMessageKeys.CommonInvalidInput);
        var result = await _profileCatalog.ReorderAsync(request.ProfileId, direction.Value, request.Position);
        return result.Status == ProfileCatalogStatus.Completed ? OperationView.Ok(ApiMessageKeys.ProfileOrderSaved)
            : ProfileCatalogContractMapper.Failure(result);
    }

    public async Task<OperationView> SortProfilesAsync(SortProfilesRequest request)
    {
        var result = await _profileCatalog.SortAsync(request.SubscriptionId, request.Column, request.Ascending);
        return result.Status == ProfileCatalogStatus.Completed ? OperationView.Ok(ApiMessageKeys.ProfileOrderSaved)
            : ProfileCatalogContractMapper.Failure(result);
    }

    public Task<OperationView> RemoveDuplicateProfilesAsync(string? subscriptionId) =>
        _coreLifecycle.ExecuteAsync(async () => OperationView.Ok(ApiMessageKeys.ProfileDeduplicated,
            new { removed = await _profileMaintenance.CleanAsync(subscriptionId, duplicates: true) }), CancellationToken.None);

    public Task<OperationView> RemoveInvalidProfilesAsync(string? subscriptionId) =>
        _coreLifecycle.ExecuteAsync(async () =>
        {
            var count = await _profileMaintenance.CleanAsync(subscriptionId, duplicates: false);
            return OperationView.Ok(count < 0 ? ApiMessageKeys.CommonCompleted : ApiMessageKeys.ProfileInvalidRemoved,
                new { removed = Math.Max(count, 0) });
        }, CancellationToken.None);

    public async Task<OperationView> GenerateProfileGroupsAsync(string? subscriptionId, bool byRegion)
    {
        var result = await _profileMaintenance.GenerateAsync(subscriptionId, byRegion);
        if (result.MissingGroup) return OperationView.Fail("subscription_not_found", ApiMessageKeys.SubscriptionNotFound);
        object? data = result.Result.SingleId ?? (object?)result.Result.MultipleIds;
        return result.Result.Success ? OperationView.Ok(ApiMessageKeys.ProfileGrouped, data)
            : OperationView.Fail("profile_group_empty", ApiMessageKeys.ProfileGrouped, data);
    }

    public async Task<IReadOnlyList<ProfileExportItem>> ExportProfileDataAsync(ProfileExportRequest request) =>
        (await _profileExport.ExportAsync(new(request.ProfileIds, request.IncludeShareUris, request.Base64ShareUris,
            request.IncludeInnerUri, request.IncludeClientConfig)))
        .Select(item => new ProfileExportItem(item.ProfileId, item.Remarks, item.Format, item.Content)).ToArray();

    public Task<string?> GetSubscriptionShareAsync(string id) => ServiceLibProfileQueries.ReadSubscriptionShareAsync(id);

    public async Task<OperationView> StartSpeedTestAsync(SpeedTestRequest request, CancellationToken cancellationToken, bool singleProfile = false)
    {
        var action = request.Action switch
        {
            ESpeedActionType.Tcping => V2rayM.Domain.Diagnostics.SpeedTestAction.Tcping,
            ESpeedActionType.Realping or ESpeedActionType.FastRealping => V2rayM.Domain.Diagnostics.SpeedTestAction.Realping,
            ESpeedActionType.UdpTest => V2rayM.Domain.Diagnostics.SpeedTestAction.UdpTest,
            ESpeedActionType.Speedtest => V2rayM.Domain.Diagnostics.SpeedTestAction.Speedtest,
            ESpeedActionType.Mixedtest => V2rayM.Domain.Diagnostics.SpeedTestAction.Mixedtest,
            _ => (V2rayM.Domain.Diagnostics.SpeedTestAction?)null,
        };
        if (action is null) return OperationView.Fail("speedtest_action_invalid", ApiMessageKeys.CommonInvalidInput);
        var result = await _speedTests.StartAsync(action.Value, request.ProfileIds, cancellationToken, singleProfile);
        return result.Admission switch
        {
            V2rayM.Application.Diagnostics.SpeedTestAdmission.InvalidProfile => OperationView.Fail("speedtest_invalid_profile", ApiMessageKeys.SpeedTestInvalidProfile),
            V2rayM.Application.Diagnostics.SpeedTestAdmission.Empty => OperationView.Fail("speedtest_profile_selection_required", ApiMessageKeys.SpeedTestSelectRequired),
            V2rayM.Application.Diagnostics.SpeedTestAdmission.Unsupported => OperationView.Fail("speedtest_core_unsupported", ApiMessageKeys.SpeedTestUnsupportedCore),
            V2rayM.Application.Diagnostics.SpeedTestAdmission.Busy => OperationView.Fail("speedtest_busy", ApiMessageKeys.SpeedTestBusy),
            _ => OperationView.Ok(ApiMessageKeys.SpeedTestStarted, new { action = action.Value.ToString(), profileCount = result.Count }),
        };
    }

    public OperationView StopSpeedTests()
    {
        _speedTests.Stop();
        return OperationView.Ok(ApiMessageKeys.CommonCompleted);
    }
}
