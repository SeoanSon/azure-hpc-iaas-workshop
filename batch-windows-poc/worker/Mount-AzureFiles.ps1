Set-StrictMode -Version Latest
. "$PSScriptRoot\Blob-Helpers.ps1"
. "$PSScriptRoot\Sql-Helpers.ps1"

function Get-KeyVaultSecretValue {
    param([string]$VaultUrl, [string]$SecretName, [string]$ClientId)
    $token = Get-MsiAccessToken -Resource 'https://vault.azure.net' -ClientId $ClientId
    $headers = @{ Authorization = "Bearer $token" }
    $url = "$($VaultUrl.TrimEnd('/'))/secrets/$([uri]::EscapeDataString($SecretName))?api-version=7.4"
    $secret = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 20
    if (-not $secret.value) { throw 'FILESHARE_KEY_SECRET_EMPTY' }
    return [string]$secret.value
}

function Connect-AzureFileShare {
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [Parameter(Mandatory)][string]$ShareName,
        [Parameter(Mandatory)][string]$AccountKey,
        [int]$TimeoutSeconds = 30
    )

    $unc = "\\$AccountName.file.core.windows.net\$ShareName"
    $drive = 'X:'
    $attemptJob = Start-Job -ScriptBlock {
        param($Path, $Share, $User, $Key)
        New-SmbMapping -LocalPath $Path -RemotePath $Share -UserName $User -Password $Key -Persistent:$false -ErrorAction Stop | Out-Null
        if (-not (Test-Path -LiteralPath "$Share\")) { throw 'SMB_SHARE_UNAVAILABLE' }
    } -ArgumentList $drive, $unc, "AZURE\$AccountName", $AccountKey
    try {
        if (-not (Wait-Job -Job $attemptJob -Timeout $TimeoutSeconds)) {
            Stop-Job -Job $attemptJob -ErrorAction SilentlyContinue
            throw 'MOUNT_TIMEOUT'
        }
        $result = Receive-Job -Job $attemptJob -ErrorAction Stop
        return @{ Unc = $unc; Drive = $drive; Detail = ($result -join '; ') }
    } finally { Remove-Job -Job $attemptJob -Force -ErrorAction SilentlyContinue }
}

function Mount-AzureFileShareWithRetry {
    param([hashtable]$Payload, [long]$RunId, [int]$MaxRetries = 3, [int]$TimeoutSeconds = 30)

    $lastError = 'MOUNT_FAILED'
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $started = [DateTimeOffset]::UtcNow
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $success = $false
        $attemptFailed = $false
        try {
            try {
                $key = Get-KeyVaultSecretValue -VaultUrl $Payload.keyVaultUrl -SecretName $Payload.fileShareKeySecretName -ClientId $Payload.workerIdentityClientId
            } catch {
                throw 'MOUNT_KEYVAULT_UNAVAILABLE'
            }
            $connection = Connect-AzureFileShare -AccountName $Payload.fileShareAccountName -ShareName $Payload.fileShareName -AccountKey $key -TimeoutSeconds $TimeoutSeconds
            $success = $true
            return $connection
        } catch {
            $lastError = if ($_.Exception.Message -eq 'MOUNT_TIMEOUT') { 'MOUNT_TIMEOUT' } elseif ($_.Exception.Message -eq 'MOUNT_KEYVAULT_UNAVAILABLE') { 'MOUNT_KEY_UNAVAILABLE' } else { 'MOUNT_CONNECT_FAILED' }
            $attemptFailed = $true
        } finally {
            $timer.Stop()
            $completed = [DateTimeOffset]::UtcNow
            $mode = [string]$Payload.copyMode
            $query = @'
INSERT dbo.mount_metrics(job_id,run_id,copy_mode,operation,attempt,started_at,completed_at,latency_ms,success,error_code,detail)
VALUES(@job,@run,@mode,'smb_mount',@attempt,@start,@end,@ms,@success,@error,@detail);
UPDATE dbo.job_runs SET mount_started_at=COALESCE(mount_started_at,@start),mount_completed_at=@end,
 mount_latency_ms=@ms,mount_error_code=CASE WHEN @success=1 THEN NULL ELSE @error END,mount_retry_count=@attempt-1
WHERE id=@run;
'@
            Invoke-PocSql -ConnectionString $Payload.sqlConnectionString -ClientId $Payload.workerIdentityClientId -Query $query -Parameters @{
                job = $Payload.jobId; run = $RunId; mode = $mode; attempt = $attempt
                start = $started.UtcDateTime; end = $completed.UtcDateTime; ms = [long]$timer.ElapsedMilliseconds
                success = $success; error = if ($success) { $null } else { $lastError }
                detail = if ($success) { 'Azure Files SMB 3.x 연결을 설정했습니다.' } else { $lastError }
            } | Out-Null
        }
        if ($attemptFailed -and $attempt -lt $MaxRetries) { Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt - 1))) }
    }
    throw $lastError
}
