using V2rayM.Application.Profiles;
using V2rayM.Domain.Profiles;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal static class ProfileEditorContractMapper
{
    internal static (string Code, string Key) Validation(ProfileValidation validation) => validation switch
    {
        ProfileValidation.Valid => ("ok", string.Empty),
        ProfileValidation.Unsupported => ("xray_only_profile_required", ApiMessageKeys.ProfileInvalid),
        ProfileValidation.InvalidGroup => ("profile_group_invalid", ApiMessageKeys.ProfileInvalid),
        ProfileValidation.RequiresImport => ("profile_complex_type_requires_import", ApiMessageKeys.CommonInvalidInput),
        ProfileValidation.InvalidHttpHeaders => ("profile_http_headers_invalid", ApiMessageKeys.ProfileInvalid),
        _ => ("profile_validation_failed", ApiMessageKeys.ProfileInvalid),
    };
    internal static OperationView Result(ProfileSaveResult result, string? restartCode)
    {
        var validation = Validation(result.Validation);
        return result.Status switch
        {
            ProfileSaveStatus.Saved => OperationView.Ok(ApiMessageKeys.ProfileSaved, new { profileId = result.Id, coreRestarted = result.Restarted }),
            ProfileSaveStatus.NotFound => OperationView.Fail("profile_not_found", ApiMessageKeys.ProfileNotFound),
            ProfileSaveStatus.ImmutableProtocol => OperationView.Fail("profile_config_type_immutable", ApiMessageKeys.ProfileInvalid),
            ProfileSaveStatus.GroupNotFound => OperationView.Fail("subscription_not_found", ApiMessageKeys.SubscriptionNotFound,
                result.GroupId is null ? null : new { subscriptionId = result.GroupId }),
            ProfileSaveStatus.InvalidChildren => OperationView.Fail("profile_group_children_invalid", ApiMessageKeys.ProfileInvalid),
            ProfileSaveStatus.ValidationFailed => OperationView.Fail(validation.Code, validation.Key),
            ProfileSaveStatus.PersistenceFailed => OperationView.Fail("profile_persistence_failed", ApiMessageKeys.ProfileSaveFailed,
                new { stage = "servicelib_or_sqlite_write", exceptionType = result.Error!.GetType().Name, detail = result.Error.Message }),
            ProfileSaveStatus.Rejected => OperationView.Fail("profile_save_rejected", ApiMessageKeys.ProfileSaveFailed,
                new { stage = "servicelib_validation_or_persistence", result = result.PersistenceCode }),
            ProfileSaveStatus.RestartFailed => OperationView.Fail("profile_saved_core_restart_failed", ApiMessageKeys.ProfileSaved,
                new { profileId = result.Id, coreRestartRequired = true, coreResultCode = restartCode }),
            _ => throw new ArgumentOutOfRangeException(nameof(result)),
        };
    }
}
