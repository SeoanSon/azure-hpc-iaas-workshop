param([Parameter(Mandatory)][string]$PayloadBase64)
Set-StrictMode -Version Latest
. "$PSScriptRoot\Blob-Helpers.ps1"
. "$PSScriptRoot\Sql-Helpers.ps1"

$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadBase64)) | ConvertFrom-Json
$item = Get-Item -LiteralPath $payload.path
$blobName = "$($payload.jobId)/$($payload.relativeName -replace '\\','/')"
$timer = [Diagnostics.Stopwatch]::StartNew()
$started = [DateTimeOffset]::UtcNow
$retryCount = 0
$result = $null
$errorCode = $null
try {
    for ($attempt = 0; $attempt -le 3; $attempt++) {
        try {
            if ($attempt -gt 0) { $retryCount++; Start-Sleep -Seconds ([Math]::Min(16, [Math]::Pow(2, $attempt))) }
            $result = Upload-BlobFromFile -AccountUrl $payload.storageAccountUrl -Container $payload.outputContainer -BlobName $blobName -Path $payload.path -ClientId $payload.workerIdentityClientId
            break
        } catch {
            $errorCode = 'ARTIFACT_UPLOAD_FAILED'
            if ($attempt -eq 3) { throw }
        }
    }
} finally {
    $timer.Stop()
    $completed = [DateTimeOffset]::UtcNow
    $query = @'
INSERT dbo.copy_metrics(job_id,run_id,copy_mode,direction,source_name,bytes,started_at,completed_at,elapsed_ms,bytes_per_second,success,retry_count,sha256,error_code)
VALUES(@job,@run,@mode,'upload',@source,@bytes,@start,@end,@ms,@rate,@success,@retries,@sha,@error);
'@
    Invoke-PocSql -ConnectionString $payload.sqlConnectionString -ClientId $payload.workerIdentityClientId -Query $query -Parameters @{
        job = $payload.jobId; run = [long]$payload.runId; mode = $payload.copyMode
        source = $payload.relativeName; bytes = [long]$item.Length
        start = $started.UtcDateTime; end = $completed.UtcDateTime; ms = [long]$timer.ElapsedMilliseconds
        rate = if ($timer.Elapsed.TotalSeconds -gt 0) { [double]$item.Length / $timer.Elapsed.TotalSeconds } else { 0 }
        success = ($null -ne $result); retries = $retryCount
        sha = if ($null -ne $result) { $result.Sha256 } else { $null }; error = $errorCode
    } | Out-Null
}
if ($null -eq $result) { throw $errorCode }

$artifact = @'
INSERT dbo.job_artifacts(job_id,name,blob_name,content_type,bytes,sha256,created_at)
VALUES(@job,@name,@blob,@content,@bytes,@sha,SYSUTCDATETIME());
'@
$contentType = switch ([IO.Path]::GetExtension([string]$payload.relativeName).ToLowerInvariant()) {
    '.txt' { 'text/plain' }
    '.json' { 'application/json' }
    '.log' { 'text/plain' }
    default { 'application/octet-stream' }
}
Invoke-PocSql -ConnectionString $payload.sqlConnectionString -ClientId $payload.workerIdentityClientId -Query $artifact -Parameters @{
    job = $payload.jobId; name = $payload.relativeName; blob = $blobName
    content = $contentType; bytes = [long]$result.Bytes; sha = $result.Sha256
} | Out-Null
Write-Output $blobName
