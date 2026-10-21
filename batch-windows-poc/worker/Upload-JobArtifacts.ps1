Set-StrictMode -Version Latest
. "$PSScriptRoot\Sql-Helpers.ps1"

function Upload-JobArtifacts {
    param([hashtable]$Payload, [long]$RunId, [string]$WorkingDirectory, [string]$InputDirectory, [string]$CacheDirectory)

    $exclude = @($InputDirectory, $CacheDirectory, (Join-Path $WorkingDirectory 'application.exe'))
    $files = Get-ChildItem -LiteralPath $WorkingDirectory -File -Recurse | Where-Object {
        $candidate = $_.FullName
        -not ($exclude | Where-Object { $candidate.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) -or $candidate -eq $_ })
    }
    $workers = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    $maxParallel = 4
    $uploadFailed = $true
    try {
    foreach ($file in $files) {
        while (($workers | Where-Object { $_.State -eq 'Running' }).Count -ge $maxParallel) {
            $finished = Wait-Job -Job $workers -Any
            try { $results.AddRange([object[]](Receive-Job -Job $finished -ErrorAction Stop)) }
            catch { throw 'ARTIFACT_UPLOAD_FAILED' }
            Remove-Job -Job $finished -Force
            [void]$workers.Remove($finished)
        }
        $relative = $file.FullName.Substring($WorkingDirectory.TrimEnd('\').Length + 1)
        $child = @{
            jobId = $Payload.jobId
            runId = $RunId
            path = $file.FullName
            relativeName = $relative
            copyMode = $Payload.copyMode
            storageAccountUrl = $Payload.storageAccountUrl
            outputContainer = $Payload.outputContainer
            workerIdentityClientId = $Payload.workerIdentityClientId
            sqlConnectionString = $Payload.sqlConnectionString
        }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($child | ConvertTo-Json -Compress)))
        $workers.Add((Start-Job -FilePath (Join-Path $PSScriptRoot 'Upload-OneArtifact.ps1') -ArgumentList $encoded))
    }
    while ($workers.Count -gt 0) {
        $finished = Wait-Job -Job $workers -Any
        try { $results.AddRange([object[]](Receive-Job -Job $finished -ErrorAction Stop)) }
        catch {
            $workers | Stop-Job -ErrorAction SilentlyContinue
            throw 'ARTIFACT_UPLOAD_FAILED'
        }
        Remove-Job -Job $finished -Force
        [void]$workers.Remove($finished)
    }
    $uploadFailed = $false
    return $results
    } finally {
        $workers | Where-Object { $_.State -eq 'Running' } | Stop-Job -ErrorAction SilentlyContinue
        $workers | Remove-Job -Force -ErrorAction SilentlyContinue
        $retryCount = Invoke-PocSql -ConnectionString $Payload.sqlConnectionString -ClientId $Payload.workerIdentityClientId -Query @'
SELECT COALESCE(SUM(retry_count),0) FROM dbo.copy_metrics WHERE job_id=@job AND run_id=@run AND direction='upload';
'@ -Parameters @{ job=$Payload.jobId; run=$RunId } -Scalar
        Invoke-PocSql -ConnectionString $Payload.sqlConnectionString -ClientId $Payload.workerIdentityClientId -Query @'
UPDATE dbo.job_runs SET upload_completed_at=@end,upload_retry_count=@retries,
 upload_error_code=CASE WHEN @failed=1 THEN COALESCE(upload_error_code,'ARTIFACT_UPLOAD_FAILED') ELSE upload_error_code END
WHERE id=@run;
'@ -Parameters @{ end=[DateTimeOffset]::UtcNow.UtcDateTime; retries=[int]$retryCount; failed=$uploadFailed; run=$RunId } | Out-Null
    }
}
