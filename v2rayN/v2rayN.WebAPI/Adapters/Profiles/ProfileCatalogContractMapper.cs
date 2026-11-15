using V2rayM.Application.Profiles;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal static class ProfileCatalogContractMapper
{
    public static OperationView Failure(ProfileCatalogResult result, object? data = null)
    {
        var (code, key) = result.Status switch
        {
            ProfileCatalogStatus.GroupNotFound => ("subscription_not_found", ApiMessageKeys.SubscriptionNotFound),
            ProfileCatalogStatus.ContentRequired => ("profile_content_required", ApiMessageKeys.CommonInvalidInput),
            ProfileCatalogStatus.ImportEmpty => ("profile_import_empty", ApiMessageKeys.ProfileInvalid),
            ProfileCatalogStatus.ProfileNotFound => ("profile_not_found", ApiMessageKeys.ProfileNotFound),
            ProfileCatalogStatus.CopyFailed => ("profile_copy_failed", ApiMessageKeys.CommonInvalidInput),
            ProfileCatalogStatus.MoveFailed => ("profile_move_failed", ApiMessageKeys.CommonInvalidInput),
            ProfileCatalogStatus.NotInGroup => ("profile_not_in_group", ApiMessageKeys.ProfileNotInGroup),
            ProfileCatalogStatus.ReorderFailed => ("profile_order_failed", ApiMessageKeys.CommonInvalidInput),
            ProfileCatalogStatus.SortColumnInvalid => ("profile_sort_column_invalid", ApiMessageKeys.CommonInvalidInput),
            ProfileCatalogStatus.SortFailed => ("profile_sort_failed", ApiMessageKeys.CommonInvalidInput),
            _ => throw new ArgumentOutOfRangeException(nameof(result)),
        };
        return OperationView.Fail(code, key, data);
    }
}
