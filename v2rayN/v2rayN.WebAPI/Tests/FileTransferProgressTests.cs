using ServiceLib.Models.Dto;
using System.Text.Json;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Tests;

public class FileTransferProgressTests
{
    private static FileDownloadState State(long downloaded, long total, bool completed = false) => new()
    {
        Request = new() { FileUrl = "https://example.invalid/fixture", FilePath = "fixture" },
        DownloadedBytes = downloaded, TotalBytes = total, Completed = completed,
    };

    [Test]
    public async Task CompletedFilesRemainInTheAggregateDownloadProgress()
    {
        var progress = FileTransferProgress.FromStates([State(100, 100, true), State(40, 100)]);
        await (progress.DownloadedBytes == 140).Should().BeTrue();
        await (progress.TotalBytes == 200).Should().BeTrue();
        await (progress.CompletedFiles == 1).Should().BeTrue();
    }

    [Test]
    public async Task UnknownContentLengthDoesNotProduceAnInventedPercentage()
    {
        var progress = FileTransferProgress.FromStates([State(100, 100, true), State(40, 0)]);
        await (progress.TotalBytes is null).Should().BeTrue();
        await (progress.TotalFiles == 2).Should().BeTrue();
    }

    [Test]
    public async Task ExistingUpdateProgressClientsRemainCompatibleWithOptionalByteFields()
    {
        var progress = new CoreUpdateProgressView("Xray", "downloading", false, false, false, null, null,
            DownloadedBytes: 50, TotalBytes: 100);
        var json = JsonSerializer.SerializeToElement(progress, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        await (json.GetProperty("downloadedBytes").GetInt64() == 50).Should().BeTrue();
        await (json.GetProperty("totalBytes").GetInt64() == 100).Should().BeTrue();
        await json.GetProperty("isComplete").GetBoolean().Should().BeFalse();
    }
}
