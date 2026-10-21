using Azure.Storage.Blobs;
using Azure.Storage.Sas;
using Azure.Core;
using BatchPoc.Api;
using BatchPoc.Api.Services;
using Microsoft.Data.SqlClient;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using System.Security.Claims;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
var runtime = builder.Configuration.GetSection("Azure").Get<RuntimeOptions>()
    ?? throw new InvalidOperationException("Azure 설정을 찾을 수 없습니다.");
if (string.IsNullOrWhiteSpace(runtime.SqlConnectionString) ||
    string.IsNullOrWhiteSpace(runtime.StorageAccountUrl) ||
    string.IsNullOrWhiteSpace(runtime.BatchEndpoint) ||
    string.IsNullOrWhiteSpace(runtime.BatchPoolId))
    throw new InvalidOperationException("Azure:SqlConnectionString, StorageAccountUrl, BatchEndpoint, BatchPoolId 설정이 필요합니다.");

var credential = AzureCredentialFactory.Create(builder.Configuration, builder.Environment);
var tenantId = builder.Configuration["Authentication:TenantId"];
var audience = builder.Configuration["Authentication:Audience"];
if (!builder.Environment.IsDevelopment() &&
    (string.IsNullOrWhiteSpace(tenantId) || string.IsNullOrWhiteSpace(audience)))
    throw new InvalidOperationException("Development 환경이 아니면 Authentication:TenantId 및 Authentication:Audience 설정이 필요합니다.");
builder.Services.AddSingleton(runtime);
builder.Services.AddSingleton(credential);
builder.Services.AddSingleton<SqlStore>();
builder.Services.AddHttpClient<BatchRestClient>(client => client.Timeout = TimeSpan.FromSeconds(60));
builder.Services.AddHostedService<JobMonitor>();
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer(options =>
{
    options.MapInboundClaims = false;
    if (!string.IsNullOrWhiteSpace(tenantId))
        options.Authority = $"https://login.microsoftonline.com/{tenantId}/v2.0";
    if (!string.IsNullOrWhiteSpace(audience))
        options.Audience = audience;
});
builder.Services.AddAuthorization(options => options.AddPolicy("ApiUser", policy =>
    policy.RequireAuthenticatedUser().RequireAssertion(context =>
        context.User.FindFirst("scp")?.Value.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Contains("user_impersonation", StringComparer.Ordinal) == true)));
var app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();

app.MapPost("/jobs", async (SubmitJobRequest request, ClaimsPrincipal user, SqlStore sql, BatchRestClient batch, RuntimeOptions options, CancellationToken ct) =>
{
    if (request.Inputs is null || request.Inputs.Count is < 1 or > 100 ||
        request.Inputs.Any(i => i is null) ||
        request.Arguments is null || request.Arguments.Count > 100 ||
        string.IsNullOrWhiteSpace(request.ExecutableBlob) ||
        string.IsNullOrWhiteSpace(request.ExecutableVersion) ||
        request.TimeoutSeconds is < 1 or > 86400 ||
        request.CopyMode is not ("azureFiles" or "blob"))
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["request"] = ["필수 입력값이 없거나 허용 범위를 벗어났습니다."] });
    if (!InputValidation.IsSafeBlobName(request.ExecutableBlob) ||
        request.Inputs.Any(i => !InputValidation.IsSafeBlobName(i.BlobName)))
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["blobName"] = ["Blob 이름은 상위 경로 이동 구간이 없는 상대 경로여야 합니다."] });
    if ((request.ExecutableSha256 is not null && !System.Text.RegularExpressions.Regex.IsMatch(request.ExecutableSha256, "^[a-fA-F0-9]{64}$")) ||
        request.Inputs.Any(i => (i.ExpectedBytes.HasValue && i.ExpectedBytes.Value < 0) ||
            (i.ExpectedSha256 is not null && !System.Text.RegularExpressions.Regex.IsMatch(i.ExpectedSha256, "^[a-fA-F0-9]{64}$"))))
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["integrity"] = ["SHA-256 값은 16진수 64자여야 하며 바이트 크기는 음수일 수 없습니다."] });
    if (request.Arguments.Any(arg => arg is null || arg.Contains('\0')) || request.Arguments.Sum(x => x.Length) > 16_000)
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["arguments"] = ["인자에 널 문자가 있거나 전체 길이 제한을 초과했습니다."] });
    if (request.Inputs.Select(i => i.BlobName).Distinct(StringComparer.OrdinalIgnoreCase).Count() != request.Inputs.Count)
        return Results.ValidationProblem(new Dictionary<string, string[]> { ["inputs"] = ["입력 Blob 이름은 중복될 수 없습니다."] });
    var owner = user.FindFirst("oid")?.Value;
    if (string.IsNullOrWhiteSpace(owner))
        return Results.Forbid();

    var id = $"poc-{Guid.NewGuid():N}";
    var now = DateTimeOffset.UtcNow;
    await using (var connection = await sql.OpenAsync(ct))
    await using (var transaction = (SqlTransaction)await connection.BeginTransactionAsync(ct))
    {
        var insert = SqlStore.Command(connection,
            """
            INSERT dbo.jobs(id,submitted_by,status,copy_mode,executable_blob,executable_version,executable_sha256,arguments_json,timeout_seconds,created_at,updated_at)
            VALUES(@id,@owner,'queued',@mode,@exe,@version,@exeSha,@args,@timeout,@now,@now);
            INSERT dbo.job_runs(job_id,run_number,status,queued_at,created_at)
            VALUES(@id,1,'queued',@now,@now);
            INSERT dbo.job_events(job_id,event_type,event_time,detail_json)
            VALUES(@id,'queued',@now,@detail);
            """, ("@id", id), ("@owner", owner), ("@mode", request.CopyMode), ("@exe", request.ExecutableBlob),
            ("@version", request.ExecutableVersion), ("@exeSha", request.ExecutableSha256),
            ("@args", JsonSerializer.Serialize(request.Arguments)),
            ("@timeout", request.TimeoutSeconds), ("@now", now.UtcDateTime),
            ("@detail", JsonSerializer.Serialize(new { inputCount = request.Inputs.Count })));
        insert.Transaction = transaction;
        await insert.ExecuteNonQueryAsync(ct);
        for (var index = 0; index < request.Inputs.Count; index++)
        {
            var input = request.Inputs[index];
            var addInput = SqlStore.Command(connection,
                """
                INSERT dbo.job_inputs(job_id,input_index,blob_name,expected_bytes,expected_sha256,status)
                VALUES(@id,@index,@blob,@bytes,@sha,'queued')
                """, ("@id", id), ("@index", index), ("@blob", input.BlobName),
                ("@bytes", input.ExpectedBytes), ("@sha", input.ExpectedSha256));
            addInput.Transaction = transaction;
            await addInput.ExecuteNonQueryAsync(ct);
        }
        await transaction.CommitAsync(ct);
    }

    var payload = JsonSerializer.Serialize(new
    {
        jobId = id,
        copyMode = request.CopyMode,
        executableBlob = request.ExecutableBlob,
        executableVersion = request.ExecutableVersion,
        expectedExecutableSha256 = request.ExecutableSha256,
        arguments = request.Arguments,
        inputs = request.Inputs,
        timeoutSeconds = request.TimeoutSeconds,
        inputContainer = options.InputContainer,
        outputContainer = options.OutputContainer,
        payloadContainer = options.PayloadContainer,
        storageAccountUrl = options.StorageAccountUrl,
        poolId = options.PoolId,
        fileShareAccountName = options.FileShareAccountName,
        fileShareName = options.FileShareName,
        keyVaultUrl = options.KeyVaultUrl,
        fileShareKeySecretName = options.FileShareKeySecretName,
        workerIdentityClientId = options.WorkerManagedIdentityClientId,
        sqlConnectionString = options.SqlConnectionString
    });
    var submitStarted = DateTimeOffset.UtcNow;
    await using (var connection = await sql.OpenAsync(ct))
    await using (var command = SqlStore.Command(connection,
        "UPDATE dbo.job_runs SET submit_started_at=@started WHERE job_id=@id AND run_number=1",
        ("@started", submitStarted.UtcDateTime), ("@id", id)))
        await command.ExecuteNonQueryAsync(ct);
    try
    {
        await batch.SubmitAsync(id, "execute", payload, ct);
    }
    catch (Exception ex)
    {
        await MarkSubmissionFailureAsync(sql, id, ex, ct);
        return Results.Problem(statusCode: 502, title: "Batch 작업 제출 실패", detail: "Azure Batch에 작업을 제출하지 못했습니다. 저장된 작업 이벤트에서 오류 코드를 확인하세요.");
    }
    await using (var connection = await sql.OpenAsync(ct))
    await using (var command = SqlStore.Command(connection,
        "UPDATE dbo.job_runs SET submit_completed_at=@completed WHERE job_id=@id AND run_number=1",
        ("@completed", DateTimeOffset.UtcNow.UtcDateTime), ("@id", id)))
        await command.ExecuteNonQueryAsync(ct);
    return Results.Accepted($"/jobs/{id}", new SubmitJobResponse(id, "queued"));
}).RequireAuthorization("ApiUser");

app.MapGet("/jobs/{id}", async (string id, ClaimsPrincipal user, SqlStore sql, CancellationToken ct) =>
{
    var owner = user.FindFirst("oid")?.Value;
    if (string.IsNullOrWhiteSpace(owner)) return Results.Forbid();
    await using var connection = await sql.OpenAsync(ct);
    await using var command = SqlStore.Command(connection,
        """
        SELECT id,status,copy_mode,created_at,started_at,completed_at,error_code,error_message
        FROM dbo.jobs WHERE id=@id AND submitted_by=@owner
        """, ("@id", id), ("@owner", owner));
    await using var reader = await command.ExecuteReaderAsync(ct);
    if (!await reader.ReadAsync(ct))
        return Results.NotFound();
    return Results.Ok(new JobStatusResponse(
        reader.GetString(0), reader.GetString(1), reader.GetString(2),
        reader.GetDateTimeOffset(3),
        reader.IsDBNull(4) ? null : reader.GetDateTimeOffset(4),
        reader.IsDBNull(5) ? null : reader.GetDateTimeOffset(5),
        reader.IsDBNull(6) ? null : reader.GetString(6),
        reader.IsDBNull(7) ? null : reader.GetString(7)));
}).RequireAuthorization("ApiUser");

app.MapGet("/jobs/{id}/artifacts", async (string id, ClaimsPrincipal user, SqlStore sql, RuntimeOptions options, TokenCredential credential, CancellationToken ct) =>
{
    var owner = user.FindFirst("oid")?.Value;
    if (string.IsNullOrWhiteSpace(owner)) return Results.Forbid();
    if (await GetStatusAsync(sql, id, owner, ct) is null) return Results.NotFound();
    var artifacts = new List<(string Name, string Blob, long Bytes, string? Sha)>();
    await using (var connection = await sql.OpenAsync(ct))
    await using (var command = SqlStore.Command(connection,
        """
        SELECT a.name,a.blob_name,a.bytes,a.sha256
        FROM dbo.job_artifacts a JOIN dbo.jobs j ON j.id=a.job_id
        WHERE a.job_id=@id AND j.submitted_by=@owner ORDER BY a.created_at
        """, ("@id", id), ("@owner", owner)))
    await using (var reader = await command.ExecuteReaderAsync(ct))
        while (await reader.ReadAsync(ct))
            artifacts.Add((reader.GetString(0), reader.GetString(1), reader.GetInt64(2), reader.IsDBNull(3) ? null : reader.GetString(3)));

    var service = new BlobServiceClient(new Uri(options.StorageAccountUrl), credential);
    var container = service.GetBlobContainerClient(options.OutputContainer);
    var delegationKey = await service.GetUserDelegationKeyAsync(
        DateTimeOffset.UtcNow.AddMinutes(-2),
        DateTimeOffset.UtcNow.AddMinutes(options.ArtifactSasMinutes), ct);
    var response = artifacts.Select(item =>
    {
        var blob = container.GetBlobClient(item.Blob);
        var sas = new BlobSasBuilder
        {
            BlobContainerName = options.OutputContainer,
            BlobName = item.Blob,
            Resource = "b",
            StartsOn = DateTimeOffset.UtcNow.AddMinutes(-2),
            ExpiresOn = DateTimeOffset.UtcNow.AddMinutes(options.ArtifactSasMinutes)
        };
        sas.SetPermissions(BlobSasPermissions.Read);
        return new ArtifactResponse(item.Name, $"{blob.Uri}?{sas.ToSasQueryParameters(delegationKey.Value, service.AccountName)}", item.Bytes, item.Sha);
    });
    return Results.Ok(response);
}).RequireAuthorization("ApiUser");

app.MapPost("/jobs/{id}/cancel", async (string id, ClaimsPrincipal user, SqlStore sql, BatchRestClient batch, CancellationToken ct) =>
{
    var owner = user.FindFirst("oid")?.Value;
    if (string.IsNullOrWhiteSpace(owner)) return Results.Forbid();
    var status = await GetStatusAsync(sql, id, owner, ct);
    if (status is null)
        return Results.NotFound();
    if (status is "succeeded" or "failed" or "mount_failed" or "upload_failed")
        return Results.Conflict(new { error = "작업이 이미 종료 상태입니다.", status });
    try
    {
        await batch.CancelAsync(id, "execute", ct);
        await SetCancelledAsync(sql, id, ct);
        return Results.Accepted($"/jobs/{id}", new { id, status = "failed", errorCode = "CANCELLED" });
    }
    catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
    {
        return Results.Conflict(new { error = "Batch 작업이 더 이상 취소 가능한 상태가 아닙니다." });
    }
}).RequireAuthorization("ApiUser");

app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }));
app.Run();

static async Task<string?> GetStatusAsync(SqlStore sql, string id, string owner, CancellationToken ct)
{
    await using var connection = await sql.OpenAsync(ct);
    await using var command = SqlStore.Command(connection,
        "SELECT status FROM dbo.jobs WHERE id=@id AND submitted_by=@owner", ("@id", id), ("@owner", owner));
    return (string?)await command.ExecuteScalarAsync(ct);
}

static async Task MarkSubmissionFailureAsync(SqlStore sql, string id, Exception exception, CancellationToken ct)
{
    var code = exception is HttpRequestException http
        ? $"BATCH_HTTP_{(int?)http.StatusCode ?? 0}" : "BATCH_SUBMIT_FAILED";
    await using var connection = await sql.OpenAsync(ct);
    await using var command = SqlStore.Command(connection,
        """
        UPDATE dbo.jobs SET status='failed',error_code=@code,error_message=@message,completed_at=SYSUTCDATETIME(),updated_at=SYSUTCDATETIME()
        WHERE id=@id AND status='queued';
        UPDATE dbo.job_runs SET status='failed',error_code=@code,completed_at=SYSUTCDATETIME()
          ,submit_completed_at=SYSUTCDATETIME(),submit_error_code=@code
        WHERE job_id=@id AND status='queued';
        INSERT dbo.job_events(job_id,event_type,event_time,detail_json)
        VALUES(@id,'submission_failed',SYSUTCDATETIME(),@detail);
        """, ("@id", id), ("@code", code), ("@message", "Azure Batch 작업 제출에 실패했습니다."),
        ("@detail", JsonSerializer.Serialize(new { errorCode = code, exception = exception.GetType().Name })));
    await command.ExecuteNonQueryAsync(ct);
}

static async Task SetCancelledAsync(SqlStore sql, string id, CancellationToken ct)
{
    await using var connection = await sql.OpenAsync(ct);
    await using var command = SqlStore.Command(connection,
        """
        UPDATE dbo.jobs SET status='failed',error_code='CANCELLED',error_message=N'작업 취소를 요청했습니다.',completed_at=SYSUTCDATETIME(),updated_at=SYSUTCDATETIME()
        WHERE id=@id AND status IN ('queued','running');
        UPDATE dbo.job_runs SET status='failed',error_code='CANCELLED',completed_at=SYSUTCDATETIME()
        WHERE job_id=@id AND status IN ('queued','running');
        INSERT dbo.job_events(job_id,event_type,event_time,detail_json)
        VALUES(@id,'cancel_requested',SYSUTCDATETIME(),'{"errorCode":"CANCELLED"}');
        """, ("@id", id));
    await command.ExecuteNonQueryAsync(ct);
}
