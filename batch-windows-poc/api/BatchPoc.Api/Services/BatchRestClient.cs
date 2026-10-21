using Azure.Core;
using Azure.Storage.Blobs;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace BatchPoc.Api.Services;

public sealed class BatchRestClient(TokenCredential credential, RuntimeOptions options, HttpClient http)
{
    private const string BatchScope = "https://batch.core.windows.net/.default";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private string WorkerDirectory => Path.IsPathRooted(options.WorkerDirectory)
        ? options.WorkerDirectory
        : Path.Combine(AppContext.BaseDirectory, options.WorkerDirectory);

    public async Task SubmitAsync(string jobId, string taskId, string payloadJson, CancellationToken ct)
    {
        await SendAsync(HttpMethod.Post, "jobs", new
        {
            id = jobId,
            poolInfo = new { poolId = options.BatchPoolId }
        }, ct);

        var blobService = new BlobServiceClient(new Uri(options.StorageAccountUrl), credential);
        var payloadBlob = blobService.GetBlobContainerClient(options.PayloadContainer).GetBlobClient($"{jobId}.json");
        try
        {
            var sas = await GetBootstrapSasAsync(blobService, ct);
            var files = Directory.GetFiles(WorkerDirectory, "*.ps1")
                .Select(path => new
                {
                    httpUrl = sas[path],
                    filePath = Path.GetFileName(path)
                }).ToArray();
            await payloadBlob.UploadAsync(BinaryData.FromString(payloadJson), overwrite: true, cancellationToken: ct);
            var command = $"powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Invoke-BatchJob.ps1 -JobId {jobId}";
            await SendAsync(HttpMethod.Post, $"jobs/{Uri.EscapeDataString(jobId)}/tasks", new
            {
                id = taskId,
                commandLine = command,
                resourceFiles = files,
                environmentSettings = new[]
                {
                    new { name = "POC_STORAGE_ACCOUNT_URL", value = options.StorageAccountUrl },
                    new { name = "POC_WORKER_MI_CLIENT_ID", value = options.WorkerManagedIdentityClientId },
                    new { name = "POC_PAYLOAD_CONTAINER", value = options.PayloadContainer }
                },
                constraints = new { maxWallClockTime = "P1D" },
                userIdentity = new
                {
                    autoUser = new { scope = "pool", elevationLevel = "nonadmin" }
                }
            }, ct);
        }
        catch
        {
            await TryDeleteJobAsync(jobId, ct);
            await payloadBlob.DeleteIfExistsAsync(cancellationToken: ct);
            throw;
        }
    }

    public async Task<JsonDocument> GetTaskAsync(string jobId, string taskId, CancellationToken ct) =>
        await SendAsync(HttpMethod.Get,
            $"jobs/{Uri.EscapeDataString(jobId)}/tasks/{Uri.EscapeDataString(taskId)}", null, ct);

    public async Task CancelAsync(string jobId, string taskId, CancellationToken ct)
    {
        await SendAsync(HttpMethod.Post,
            $"jobs/{Uri.EscapeDataString(jobId)}/tasks/{Uri.EscapeDataString(taskId)}/terminate", null, ct);
    }

    private async Task<Dictionary<string, string>> GetBootstrapSasAsync(BlobServiceClient service, CancellationToken ct)
    {
        var container = service.GetBlobContainerClient(options.BootstrapContainer);
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var delegationKey = await service.GetUserDelegationKeyAsync(
            DateTimeOffset.UtcNow.AddMinutes(-2),
            DateTimeOffset.UtcNow.AddMinutes(options.BootstrapSasMinutes + 10), ct);
        foreach (var path in Directory.GetFiles(WorkerDirectory, "*.ps1"))
        {
            var blob = container.GetBlobClient(Path.GetFileName(path));
            var builder = new Azure.Storage.Sas.BlobSasBuilder
            {
                BlobContainerName = options.BootstrapContainer,
                BlobName = Path.GetFileName(path),
                Resource = "b",
                StartsOn = DateTimeOffset.UtcNow.AddMinutes(-2),
                ExpiresOn = DateTimeOffset.UtcNow.AddMinutes(options.BootstrapSasMinutes)
            };
            builder.SetPermissions(Azure.Storage.Sas.BlobSasPermissions.Read);
            var sas = builder.ToSasQueryParameters(delegationKey.Value, service.AccountName);
            result[path] = $"{blob.Uri}?{sas}";
        }
        return result;
    }

    private async Task<JsonDocument> SendAsync(HttpMethod method, string relativePath, object? body, CancellationToken ct)
    {
        var endpoint = new Uri(options.BatchEndpoint.TrimEnd('/') + "/" + relativePath +
            (relativePath.Contains('?') ? "&" : "?") + "api-version=" + options.BatchApiVersion);
        var token = await credential.GetTokenAsync(new TokenRequestContext([BatchScope]), ct);
        using var request = new HttpRequestMessage(method, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Add("ocp-date", DateTimeOffset.UtcNow.ToString("R"));
        if (body is not null)
            request.Content = JsonContent.Create(body, options: JsonOptions);

        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        var content = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException(
                $"Azure Batch returned {(int)response.StatusCode}: {content}", null, response.StatusCode);
        return JsonDocument.Parse(string.IsNullOrWhiteSpace(content) ? "{}" : content);
    }

    private async Task TryDeleteJobAsync(string jobId, CancellationToken ct)
    {
        try
        {
            await SendAsync(HttpMethod.Delete, $"jobs/{Uri.EscapeDataString(jobId)}", null, ct);
        }
        catch (HttpRequestException)
        {
            // 최초 Batch 작업 제출 오류를 호출자에게 그대로 전달합니다.
        }
    }
}
