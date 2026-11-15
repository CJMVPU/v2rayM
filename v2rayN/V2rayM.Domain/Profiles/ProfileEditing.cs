namespace V2rayM.Domain.Profiles;

public enum ProfileKind { Simple, Group, Custom, Outbound, ImportOnly }
public enum ProfileValidation { Valid, Unsupported, Invalid, InvalidGroup, InvalidHttpHeaders, RequiresImport }
public sealed record ProfileEditFacts(int ProtocolIdentity, ProfileKind Kind, bool Supported,
    string? Name, string? Address, int Port, string? Password, bool RequiresPassword,
    bool RequiresCipher, string? Cipher, bool HeadersValid, bool HasXrayCore,
    IReadOnlyList<string> ChildIds, string? ChildGroup);
public sealed record ProfileIdentity(string Id, int ProtocolIdentity, string GroupId, bool FromSubscription);

public static class ProfileEditing
{
    public static ProfileValidation ValidateSimple(ProfileEditFacts value)
    {
        if (!value.Supported) return ProfileValidation.Unsupported;
        if (string.IsNullOrEmpty(value.Name) || string.IsNullOrEmpty(value.Address) || value.Port is <= 0 or >= 65536
            || value.RequiresPassword && string.IsNullOrEmpty(value.Password)
            || value.RequiresCipher && string.IsNullOrEmpty(value.Cipher)) return ProfileValidation.Invalid;
        return value.HeadersValid ? ProfileValidation.Valid : ProfileValidation.InvalidHttpHeaders;
    }
    public static ProfileValidation Validate(ProfileEditFacts value)
    {
        if (!value.Supported) return ProfileValidation.Unsupported;
        return value.Kind switch
        {
            ProfileKind.Group => string.IsNullOrWhiteSpace(value.Name) || !value.HasXrayCore
                || value.ChildIds.Count == 0 && string.IsNullOrWhiteSpace(value.ChildGroup)
                    ? ProfileValidation.InvalidGroup : ProfileValidation.Valid,
            ProfileKind.Custom or ProfileKind.Outbound => string.IsNullOrWhiteSpace(value.Name) || string.IsNullOrWhiteSpace(value.Address)
                ? ProfileValidation.Invalid : ProfileValidation.Valid,
            ProfileKind.ImportOnly => ProfileValidation.RequiresImport,
            _ => ValidateSimple(value),
        };
    }
}
