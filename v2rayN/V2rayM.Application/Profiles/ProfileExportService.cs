using System.Text;

namespace V2rayM.Application.Profiles;

public sealed record ProfileExportOptions(IReadOnlyList<string> ProfileIds, bool ShareUris, bool Base64ShareUris,
    bool InnerUri, bool ClientConfig);
public sealed record ProfileExportDocument(string ProfileId, string Remarks, string Format, string Content);
public interface IProfileExportSnapshot
{
    int Count { get; }
    IEnumerable<string?> ShareUris();
    string? InnerUri();
    Task<IReadOnlyList<ProfileExportDocument>> ClientConfigsAsync();
}
public interface IProfileExportSource
{
    Task<IProfileExportSnapshot> CaptureAsync(IReadOnlyList<string> ids);
}

public sealed class ProfileExportService(IProfileExportSource source, IMutationScope mutations)
{
    public Task<IReadOnlyList<ProfileExportDocument>> ExportAsync(ProfileExportOptions options) =>
        mutations.RunAsync<IReadOnlyList<ProfileExportDocument>>(async () =>
        {
            var snapshot = await source.CaptureAsync(options.ProfileIds);
            var documents = new List<ProfileExportDocument>();
            if (options.ShareUris)
            {
                var uris = snapshot.ShareUris().Where(uri => !string.IsNullOrWhiteSpace(uri)).ToArray();
                if (uris.Length > 0)
                {
                    var text = string.Join(Environment.NewLine, uris) + Environment.NewLine;
                    documents.Add(new(string.Empty, string.Empty, options.Base64ShareUris ? "share-uri-base64" : "share-uri",
                        options.Base64ShareUris ? Convert.ToBase64String(Encoding.UTF8.GetBytes(text)) : text));
                }
            }
            if (options.InnerUri && snapshot.Count > 0 && snapshot.InnerUri() is { } inner && !string.IsNullOrWhiteSpace(inner))
                documents.Add(new(string.Empty, string.Empty, "inner-uri", inner));
            if (options.ClientConfig) documents.AddRange(await snapshot.ClientConfigsAsync());
            return documents;
        });
}
