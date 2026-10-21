using System.Text.Json;

namespace BatchPoc.Api.Services;

public sealed class JobMonitor(
    IServiceScopeFactory scopes,
    ILogger<JobMonitor> logger,
    RuntimeOptions options) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(Math.Clamp(options.MonitorIntervalSeconds, 5, 300)));
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            try
            {
                await ReconcileAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Batch task reconciliation failed");
            }
        }
    }

    private async Task ReconcileAsync(CancellationToken ct)
    {
        using var scope = scopes.CreateScope();
        var sql = scope.ServiceProvider.GetRequiredService<SqlStore>();
        var batch = scope.ServiceProvider.GetRequiredService<BatchRestClient>();
        var jobs = new List<(string Id, string Status, DateTimeOffset CreatedAt)>();
        await using (var connection = await sql.OpenAsync(ct))
        await using (var command = SqlStore.Command(connection,
            "SELECT id,status,created_at FROM dbo.jobs WHERE status IN ('queued','running')"))
        await using (var reader = await command.ExecuteReaderAsync(ct))
            while (await reader.ReadAsync(ct))
                jobs.Add((reader.GetString(0), reader.GetString(1), reader.GetDateTimeOffset(2)));

        foreach (var job in jobs)
        {
            try
            {
                using var task = await batch.GetTaskAsync(job.Id, "execute", ct);
                var root = task.RootElement;
                var state = root.GetProperty("state").GetString();
                var exitCode = root.TryGetProperty("executionInfo", out var execution) &&
                    execution.TryGetProperty("exitCode", out var exit) && exit.ValueKind == JsonValueKind.Number
                    ? exit.GetInt32() : (int?)null;
                var newStatus = state switch
                {
                    "running" or "preparing" => "running",
                    "completed" => exitCode == 0 ? "succeeded" : "failed",
                    _ => job.Status
                };
                if (newStatus != job.Status)
                    await UpdateStatusAsync(sql, job.Id, newStatus, exitCode, ct,
                        newStatus == "failed" ? $"BATCH_TASK_EXIT_{exitCode?.ToString() ?? "NO_CODE"}" : null);
            }
            catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
            {
                if (DateTimeOffset.UtcNow - job.CreatedAt > TimeSpan.FromMinutes(5))
                    await UpdateStatusAsync(sql, job.Id, "failed", null, ct, "BATCH_TASK_NOT_FOUND");
            }
        }
    }

    private static async Task UpdateStatusAsync(
        SqlStore sql, string id, string status, int? exitCode, CancellationToken ct, string? errorCode = null)
    {
        await using var connection = await sql.OpenAsync(ct);
        await using var transaction = (Microsoft.Data.SqlClient.SqlTransaction)await connection.BeginTransactionAsync(ct);
        var command = SqlStore.Command(connection,
            """
            UPDATE dbo.jobs SET status=@status, started_at=COALESCE(started_at,CASE WHEN @status='running' THEN SYSUTCDATETIME() END),
              completed_at=CASE WHEN @status IN ('succeeded','failed') THEN SYSUTCDATETIME() ELSE completed_at END,
              error_code=COALESCE(error_code,@error), error_message=COALESCE(error_message,@message),
              updated_at=SYSUTCDATETIME()
            WHERE id=@id AND status IN ('queued','running');
            IF @@ROWCOUNT > 0
              INSERT dbo.job_events(job_id,event_type,event_time,detail_json)
              VALUES(@id,@status,SYSUTCDATETIME(),JSON_OBJECT('batchExitCode':@exitCode));
            """, ("@id", id), ("@status", status), ("@exitCode", exitCode),
            ("@error", errorCode),
            ("@message", errorCode is null ? null : errorCode == "BATCH_TASK_NOT_FOUND"
                ? "Azure Batch task was not found after submission grace period."
                : $"Azure Batch task ended with error code {errorCode}."));
        command.Transaction = transaction;
        await command.ExecuteNonQueryAsync(ct);
        await transaction.CommitAsync(ct);
    }
}
