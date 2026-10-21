param([Parameter(Mandatory)][string]$JobId)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Blob-Helpers.ps1"
. "$PSScriptRoot\Sql-Helpers.ps1"
. "$PSScriptRoot\Mount-AzureFiles.ps1"
. "$PSScriptRoot\Copy-JobInputs.ps1"
. "$PSScriptRoot\Invoke-Exe.ps1"
. "$PSScriptRoot\Upload-JobArtifacts.ps1"

function ConvertTo-HashtableValue($Value) {
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) { $result[$key] = ConvertTo-HashtableValue $Value[$key] }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-HashtableValue $property.Value }
        return $result
    }
    if ($Value -is [System.Array]) {
        return ,@($Value | ForEach-Object { ConvertTo-HashtableValue $_ })
    }
    return $Value
}

$payloadFile = Join-Path $PWD 'job-payload.json'
Get-BlobToFile -AccountUrl $env:POC_STORAGE_ACCOUNT_URL -Container $env:POC_PAYLOAD_CONTAINER `
    -BlobName "$JobId.json" -Destination $payloadFile -ClientId $env:POC_WORKER_MI_CLIENT_ID | Out-Null
$payload = ConvertTo-HashtableValue (Get-Content -LiteralPath $payloadFile -Raw | ConvertFrom-Json)
$payload.poolId = $env:AZ_BATCH_POOL_ID
$jobId = [string]$payload.jobId
$runId = [long](Invoke-PocSql -ConnectionString $payload.sqlConnectionString -ClientId $payload.workerIdentityClientId `
    -Query 'SELECT TOP (1) id FROM dbo.job_runs WHERE job_id=@job AND run_number=1' -Parameters @{ job = $jobId } -Scalar)
$work = Join-Path $PWD 'work'
$inputDirectory = Join-Path $work 'input'
$outputDirectory = Join-Path $work 'output'
$cacheDirectory = Join-Path $env:AZ_BATCH_NODE_SHARED_DIR 'poc-executable-cache'
New-Item -ItemType Directory -Path $inputDirectory,$outputDirectory,$cacheDirectory -Force | Out-Null
$started = [DateTimeOffset]::UtcNow
$status = 'running'
$errorCode = $null
$errorMessage = $null
$mountStarted = $false
$uploadStarted = $false
$exitCode = $null
$event = @'
UPDATE dbo.jobs SET status='running',started_at=COALESCE(started_at,@now),updated_at=@now WHERE id=@job AND status='queued';
UPDATE dbo.job_runs SET status='running',started_at=@now,node_id=@node,batch_job_id=@job,batch_task_id=@task WHERE id=@run;
INSERT dbo.job_events(job_id,event_type,event_time,detail_json) VALUES(@job,'worker_started',@now,@detail);
'@
Invoke-PocSql -ConnectionString $payload.sqlConnectionString -ClientId $payload.workerIdentityClientId -Query $event -Parameters @{
    job = $jobId; run = $runId; task = $env:AZ_BATCH_TASK_ID; node = $env:AZ_BATCH_NODE_ID
    now = $started.UtcDateTime; detail = (@{ copyMode = $payload.copyMode; nodeId = $env:AZ_BATCH_NODE_ID } | ConvertTo-Json -Compress)
} | Out-Null

try {
    $share = $null
    if ($payload.copyMode -eq 'azureFiles') {
        $mountStarted = $true
        $share = Mount-AzureFileShareWithRetry -Payload $payload -RunId $runId -MaxRetries 3 -TimeoutSeconds 30
    } else {
        $probeStart = [DateTimeOffset]::UtcNow
        $probeWatch = [Diagnostics.Stopwatch]::StartNew()
        $probeOk = $false
        $probeError = $null
        try {
            $token = Get-MsiAccessToken -Resource 'https://storage.azure.com/' -ClientId $payload.workerIdentityClientId
            $uri = Get-BlobUri $payload.storageAccountUrl $payload.inputContainer $payload.executableBlob
            Invoke-WebRequest -Method Head -Uri $uri -Headers @{ Authorization = "Bearer $token"; 'x-ms-version' = '2023-11-03' } -TimeoutSec 30 -UseBasicParsing | Out-Null
            $probeOk = $true
        } catch { $probeError = 'BLOB_CONNECTIVITY_FAILED'; throw $probeError }
        finally {
            $probeWatch.Stop()
            Invoke-PocSql -ConnectionString $payload.sqlConnectionString -ClientId $payload.workerIdentityClientId -Query @'
INSERT dbo.mount_metrics(job_id,run_id,copy_mode,operation,attempt,started_at,completed_at,latency_ms,success,error_code,detail)
VALUES(@job,@run,'blob', 'blob_probe',1,@start,@end,@ms,@success,@error,'Blob endpoint authentication/connectivity; no filesystem mount is performed.');
'@ -Parameters @{ job=$jobId; run=$runId; start=$probeStart.UtcDateTime; end=[DateTimeOffset]::UtcNow.UtcDateTime
                ms=[long]$probeWatch.ElapsedMilliseconds; success=$probeOk; error=$probeError } | Out-Null
        }
    }

    $inputs = Copy-JobInputs -Payload $payload -RunId $runId -WorkingDirectory $inputDirectory -FileShareUnc $(if ($share) { $share.Unc } else { '' })
    $exe = Get-CachedExecutable -Payload $payload -CacheRoot $cacheDirectory -WorkingDirectory $work -RunId $runId
    $resolvedArguments = @($payload.arguments | ForEach-Object {
        $argument = [string]$_
        for ($index = 0; $index -lt $inputs.Count; $index++) {
            $argument = $argument.Replace("{input:$index}", $inputs[$index])
        }
        if ($argument -match '\{input:\d+\}') { throw 'INPUT_PLACEHOLDER_OUT_OF_RANGE' }
        $argument
    })
    $execStart = [DateTimeOffset]::UtcNow
    Invoke-PocSql -ConnectionString $payload.sqlConnectionString -ClientId $payload.workerIdentityClientId -Query @'
UPDATE dbo.job_runs SET execute_started_at=@now WHERE id=@run;
INSERT dbo.job_events(job_id,event_type,event_time,detail_json) VALUES(@job,'execution_started',@now,NULL);
'@ -Parameters @{ run=$runId; job=$jobId; now=$execStart.UtcDateTime } | Out-Null
    $execution = Invoke-Exe -Executable $exe -Arguments $resolvedArguments -WorkingDirectory $outputDirectory -TimeoutSeconds ([int]$payload.timeoutSeconds)
    $exitCode = [int]$execution.ExitCode
    Set-Content -LiteralPath (Join-Path $work 'stdout.txt') -Value $execution.Stdout -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $work 'stderr.txt') -Value $execution.Stderr -Encoding UTF8
    Invoke-PocSql -ConnectionString $payload.sqlConnectionString -ClientId $payload.workerIdentityClientId -Query @'
UPDATE dbo.job_runs SET execute_completed_at=@now,exe_exit_code=@exit,
 execute_error_code=CASE WHEN @exit=0 THEN NULL WHEN @detail IS NOT NULL THEN 'EXECUTABLE_FAILED' END WHERE id=@run;
INSERT dbo.job_events(job_id,event_type,event_time,detail_json) VALUES(@job,'execution_completed',@now,@detail);
'@ -Parameters @{ run=$runId; job=$jobId; now=[DateTimeOffset]::UtcNow.UtcDateTime; exit=$exitCode
                detail=(@{ timedOut=$execution.TimedOut; exitCode=$exitCode } | ConvertTo-Json -Compress) } | Out-Null
    if ($execution.TimedOut) { throw 'EXECUTION_TIMEOUT' }
    if ($exitCode -ne 0) { throw "EXECUTABLE_EXIT_$exitCode" }

    $uploadStarted = $true
    Invoke-PocSql -ConnectionString $payload.sqlConnectionString -ClientId $payload.workerIdentityClientId -Query @'
UPDATE dbo.job_runs SET upload_started_at=@now WHERE id=@run;
'@ -Parameters @{ run=$runId; now=[DateTimeOffset]::UtcNow.UtcDateTime } | Out-Null
    Upload-JobArtifacts -Payload $payload -RunId $runId -WorkingDirectory $work -InputDirectory $inputDirectory -CacheDirectory $cacheDirectory | Out-Null
    $status = 'succeeded'
} catch {
    $message = $_.Exception.Message
    $errorCode = switch -Regex ($message) {
        '^MOUNT_TIMEOUT$' { 'MOUNT_TIMEOUT'; break }
        '^MOUNT_KEY_UNAVAILABLE$' { 'MOUNT_KEY_UNAVAILABLE'; break }
        'MOUNT_' { 'MOUNT_CONNECT_FAILED'; break }
        'BLOB_CONNECTIVITY_FAILED' { 'BLOB_CONNECTIVITY_FAILED'; break }
        'ARTIFACT_UPLOAD_FAILED' { 'UPLOAD_FAILED'; break }
        '^EXECUTION_TIMEOUT$' { 'EXECUTION_TIMEOUT'; break }
        'EXECUTABLE_EXIT_' { 'EXECUTABLE_FAILED'; break }
        'INPUT_' { $message; break }
        default { 'WORKER_FAILED' }
    }
    $status = if ($errorCode -like 'MOUNT_*') { 'mount_failed' } elseif ($uploadStarted -or $errorCode -eq 'UPLOAD_FAILED') { 'upload_failed' } else { 'failed' }
    $errorMessage = $message.Substring(0, [Math]::Min($message.Length, 2000))
    Set-Content -LiteralPath (Join-Path $work 'worker-error.txt') -Value "$errorCode`r`n$errorMessage" -Encoding UTF8
    try {
        Upload-JobArtifacts -Payload $payload -RunId $runId -WorkingDirectory $work -InputDirectory $inputDirectory -CacheDirectory $cacheDirectory | Out-Null
    } catch {
        $status = 'upload_failed'
        $errorCode = 'UPLOAD_FAILED'
        $errorMessage = "Initial failure: $message; diagnostic artifact upload failed."
    }
} finally {
    $completed = [DateTimeOffset]::UtcNow
    $finish = @'
UPDATE dbo.jobs SET status=@status,error_code=@error,error_message=@message,completed_at=@end,updated_at=@end WHERE id=@job;
UPDATE dbo.job_runs SET status=@status,completed_at=@end,error_code=@error,error_message=@message,exe_exit_code=COALESCE(exe_exit_code,@exit),
 execute_error_code=CASE WHEN execute_started_at IS NOT NULL AND @status<>'succeeded' THEN COALESCE(execute_error_code,@error) ELSE execute_error_code END,
 upload_completed_at=CASE WHEN @upload=1 THEN @end ELSE upload_completed_at END,
 upload_error_code=CASE WHEN @status='upload_failed' THEN @error ELSE upload_error_code END WHERE id=@run;
INSERT dbo.job_events(job_id,event_type,event_time,detail_json) VALUES(@job,@status,@end,@detail);
'@
    try {
        Invoke-PocSql -ConnectionString $payload.sqlConnectionString -ClientId $payload.workerIdentityClientId -Query $finish -Parameters @{
            job=$jobId; run=$runId; status=$status; error=$errorCode; message=$errorMessage
            end=$completed.UtcDateTime; exit=$exitCode; upload=$uploadStarted
            detail=(@{ errorCode=$errorCode; durationMs=([long]($completed-$started).TotalMilliseconds) } | ConvertTo-Json -Compress)
        } | Out-Null
    } catch {
        Write-Error "FINAL_STATUS_WRITE_FAILED: $($_.Exception.Message)"
        if ($status -eq 'succeeded') { $status = 'failed'; $errorCode = 'STATUS_PERSIST_FAILED' }
    }
    if ($share) { Remove-SmbMapping -LocalPath $share.Drive -Force -ErrorAction SilentlyContinue }
}
if ($status -ne 'succeeded') { exit 1 }
exit 0
