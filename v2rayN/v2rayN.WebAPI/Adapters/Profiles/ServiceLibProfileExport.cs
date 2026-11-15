using ServiceLib.Handler;
using ServiceLib.Handler.Builder;
using ServiceLib.Handler.Fmt;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using V2rayM.Application.Profiles;

namespace v2rayN.WebAPI.Adapters.Profiles;

internal sealed class ServiceLibProfileExport(Func<Config> config) : IProfileExportSource
{
    public async Task<IProfileExportSnapshot> CaptureAsync(IReadOnlyList<string> ids) =>
        new Snapshot(config(), await ConfigDbQuery.GetProfileItemsOrderedByIndexIds(ids.ToArray()));
    private sealed class Snapshot(Config config, List<ProfileItem> items) : IProfileExportSnapshot
    {
        public int Count => items.Count;
        public IEnumerable<string?> ShareUris() => items.Select(FmtHandler.GetShareUri);
        public string? InnerUri() => InnerFmt.ToUri(items);
        public async Task<IReadOnlyList<ProfileExportDocument>> ClientConfigsAsync()
        {
            var documents = new List<ProfileExportDocument>();
            foreach (var item in items)
            {
                var (context, validation) = await CoreConfigContextBuilder.Build(config, item);
                if (!validation.Success) continue;
                var generated = await CoreConfigHandler.GenerateClientConfig(context, null);
                if (generated.Success && generated.Data is string text)
                    documents.Add(new(item.IndexId, item.Remarks, "client-config", text));
            }
            return documents;
        }
    }
}
