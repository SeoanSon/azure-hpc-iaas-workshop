Set-StrictMode -Version Latest
. "$PSScriptRoot\Blob-Helpers.ps1"
. "$PSScriptRoot\Sql-Helpers.ps1"

function Copy-JobInputs {
    param([hashtable]$Payload, [long]$RunId, [string]$WorkingDirectory, [string]$FileShareUnc)

    $copied = [System.Collections.Generic.List[string]]::new()
    foreach ($inputFile in $Payload.inputs) {
        $destination = Join-Path $WorkingDirectory ([string]$inputFile.blobName -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        $started = [DateTimeOffset]::UtcNow
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $retryCount = 0
        $errorCode = $null
        $sha = $null
        $actualBytes = 0L
        try {
            for ($attempt = 0; $attempt -le 2; $attempt++) {
                try {
                    if ($attempt -gt 0) { $retryCount++; Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt))) }
                    if ($Payload.copyMode -eq 'blob') {
                        $actualBytes = Get-BlobToFile -AccountUrl $Payload.storageAccountUrl -Container $Payload.inputContainer -BlobName $inputFile.blobName -Destination $destination -ClientId $Payload.workerIdentityClientId
                    } else {
                        $source = Join-Path $FileShareUnc ([string]$inputFile.blobName)
                        Copy-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
                        $actualBytes = (Get-Item -LiteralPath $destination).Length
                    }
                    $sha = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($null -ne $inputFile.expectedBytes -and [long]$inputFile.expectedBytes -ne $actualBytes) { throw 'INPUT_SIZE_MISMATCH' }
                    if ($inputFile.expectedSha256 -and $inputFile.expectedSha256.ToLowerInvariant() -ne $sha) { throw 'INPUT_HASH_MISMATCH' }
                    $errorCode = $null
                    break
                } catch {
                    $errorCode = if ($_.Exception.Message -match 'INPUT_(SIZE|HASH)_MISMATCH') { $_.Exception.Message } else { 'INPUT_COPY_FAILED' }
                    if ($attempt -eq 2) { throw }
                }
            }
            $copied.Add($destination)
        } finally {
            $timer.Stop()
            $completed = [DateTimeOffset]::UtcNow
            $success = $null -eq $errorCode
            $bytesPerSecond = if ($timer.Elapsed.TotalSeconds -gt 0) { $actualBytes / $timer.Elapsed.TotalSeconds } else { 0 }
            $metric = @'
INSERT dbo.copy_metrics(job_id,run_id,copy_mode,direction,source_name,bytes,started_at,completed_at,elapsed_ms,bytes_per_second,success,retry_count,sha256,error_code)
VALUES(@job,@run,@mode,'download',@source,@bytes,@start,@end,@ms,@rate,@success,@retries,@sha,@error);
UPDATE dbo.job_inputs SET status=@status,started_at=COALESCE(started_at,@start),completed_at=@end,error_code=@error,retry_count=@retries
WHERE job_id=@job AND blob_name=@source;
UPDATE dbo.job_runs SET copy_started_at=COALESCE(copy_started_at,@start),copy_completed_at=@end,
 copy_error_code=CASE WHEN @success=1 THEN copy_error_code ELSE @error END,
 copy_retry_count=copy_retry_count+@retries WHERE id=@run;
'@
            Invoke-PocSql -ConnectionString $Payload.sqlConnectionString -ClientId $Payload.workerIdentityClientId -Query $metric -Parameters @{
                job = $Payload.jobId; run = $RunId; mode = [string]$Payload.copyMode; source = [string]$inputFile.blobName
                bytes = $actualBytes; start = $started.UtcDateTime; end = $completed.UtcDateTime
                ms = [long]$timer.ElapsedMilliseconds; rate = [double]$bytesPerSecond; success = $success
                retries = $retryCount; sha = $sha; error = $errorCode; status = if ($success) { 'copied' } else { 'failed' }
            } | Out-Null
        }
    }
    return ,$copied.ToArray()
}
