Set-StrictMode -Version Latest
. "$PSScriptRoot\Blob-Helpers.ps1"
. "$PSScriptRoot\Sql-Helpers.ps1"

function ConvertTo-WindowsArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (2 * $slashes + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-CachedExecutable {
    param([hashtable]$Payload, [string]$CacheRoot, [string]$WorkingDirectory, [long]$RunId)
    $download = Join-Path $WorkingDirectory 'application.exe'
    $version = [string]$Payload.executableVersion
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $started = [DateTimeOffset]::UtcNow
    $retryCount = 0
    $downloadedBytes = 0L
    $cacheHit = $false
    $errorCode = $null
    $expectedHash = $null
    $etag = $null
    $hashProvider = [Security.Cryptography.SHA256]::Create()
    try {
        $cacheName = [BitConverter]::ToString($hashProvider.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Payload.executableBlob))).Replace('-', '').ToLowerInvariant()
    } finally { $hashProvider.Dispose() }
    $cached = Join-Path $CacheRoot "$cacheName.exe"
    $sidecar = "$cached.json"
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $sourceUri = Get-BlobUri $Payload.storageAccountUrl $Payload.inputContainer $Payload.executableBlob
                $headToken = Get-MsiAccessToken -Resource 'https://storage.azure.com/' -ClientId $Payload.workerIdentityClientId
                $head = Invoke-WebRequest -Method Head -Uri $sourceUri -Headers @{ Authorization = "Bearer $headToken"; 'x-ms-version' = '2023-11-03' } -TimeoutSec 60 -UseBasicParsing
                $etag = [string]$head.Headers['ETag']
                $metadataHash = [string]$head.Headers['x-ms-meta-sha256']
                if ((Test-Path -LiteralPath $cached) -and (Test-Path -LiteralPath $sidecar)) {
                    try {
                        $cacheRecord = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json
                        $localHash = (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash.ToLowerInvariant()
                        $cacheHit = ($cacheRecord.version -eq $version -and $cacheRecord.etag -eq $etag -and $cacheRecord.sha256 -eq $localHash)
                        if ($cacheHit) { $expectedHash = $localHash }
                    } catch {
                        $cacheHit = $false
                    }
                }
                if (-not $cacheHit) {
                    $downloadedBytes = Get-BlobToFile -AccountUrl $Payload.storageAccountUrl -Container $Payload.inputContainer -BlobName $Payload.executableBlob -Destination $download -ClientId $Payload.workerIdentityClientId
                    $actualHash = (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($Payload.expectedExecutableSha256 -and $actualHash -ne $Payload.expectedExecutableSha256.ToLowerInvariant()) { throw 'EXECUTABLE_HASH_MISMATCH' }
                    if ($metadataHash -match '^[A-Fa-f0-9]{64}$' -and $actualHash -ne $metadataHash.ToLowerInvariant()) { throw 'EXECUTABLE_HASH_MISMATCH' }
                    Copy-Item -LiteralPath $download -Destination $cached -Force
                    $expectedHash = $actualHash
                    @{ version = $version; etag = $etag; sha256 = $actualHash } | ConvertTo-Json -Compress | Set-Content -LiteralPath $sidecar -Encoding UTF8
                }
                break
            } catch {
                if ($_.Exception.Message -eq 'EXECUTABLE_HASH_MISMATCH') { throw }
                $retryCount++
                if ($attempt -eq 3) { throw 'EXECUTABLE_CACHE_FAILED' }
                Start-Sleep -Seconds ([Math]::Min(8, [Math]::Pow(2, $attempt - 1)))
            }
        }
    } catch {
        $errorCode = if ($_.Exception.Message -eq 'EXECUTABLE_HASH_MISMATCH') { 'EXECUTABLE_HASH_MISMATCH' } else { 'EXECUTABLE_CACHE_FAILED' }
        throw $errorCode
    } finally {
        $timer.Stop()
        $copyMetric = @'
INSERT dbo.copy_metrics(job_id,run_id,copy_mode,direction,source_name,bytes,started_at,completed_at,elapsed_ms,bytes_per_second,success,retry_count,sha256,error_code)
VALUES(@job,@run,@mode,'exe_cache',@source,@bytes,@start,@end,@ms,@rate,@success,@retries,@sha,@error);
'@
        Invoke-PocSql -ConnectionString $Payload.sqlConnectionString -ClientId $Payload.workerIdentityClientId -Query $copyMetric -Parameters @{
            job = $Payload.jobId; run = $RunId; mode = $Payload.copyMode; source = $Payload.executableBlob
            bytes = $downloadedBytes; start = $started.UtcDateTime; end = [DateTimeOffset]::UtcNow.UtcDateTime
            ms = [long]$timer.ElapsedMilliseconds
            rate = if ($timer.Elapsed.TotalSeconds -gt 0) { [double]$downloadedBytes / $timer.Elapsed.TotalSeconds } else { 0 }
            success = ($null -eq $errorCode); retries = $retryCount; sha = $expectedHash; error = $errorCode
        } | Out-Null
    }
    $nodeId = $env:AZ_BATCH_NODE_ID
    $query = @'
MERGE dbo.node_cache AS target
USING (SELECT @pool AS pool_id,@node AS node_id,@blob AS executable_blob) AS source
ON target.pool_id=source.pool_id AND target.node_id=source.node_id AND target.executable_blob=source.executable_blob
WHEN MATCHED THEN UPDATE SET executable_version=@version,sha256=@sha,local_path=@path,verified_at=SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT(pool_id,node_id,executable_blob,executable_version,sha256,local_path,verified_at)
VALUES(@pool,@node,@blob,@version,@sha,@path,SYSUTCDATETIME());
'@
    Invoke-PocSql -ConnectionString $Payload.sqlConnectionString -ClientId $Payload.workerIdentityClientId -Query $query -Parameters @{
        pool = $Payload.poolId; node = $nodeId; blob = $Payload.executableBlob
        version = $version; sha = $expectedHash; path = $cached
    } | Out-Null
    return $cached
}

function Invoke-Exe {
    param([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Arguments = ($Arguments | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'EXECUTABLE_START_FAILED' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        $process.WaitForExit()
        return @{ ExitCode = 124; Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult(); TimedOut = $true }
    }
    return @{ ExitCode = $process.ExitCode; Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult(); TimedOut = $false }
}
