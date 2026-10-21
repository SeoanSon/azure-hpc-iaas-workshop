param(
    [Parameter(Mandatory)][string]$ManifestCsv,
    [Parameter(Mandatory)][string]$SqlServerFqdn,
    [string]$Database = 'batchpoc',
    [string]$OutputDirectory = '.\report'
)
$ErrorActionPreference = 'Stop'
$manifest = Import-Csv -LiteralPath $ManifestCsv
if ($manifest.Count -eq 0) { throw "No job rows in $ManifestCsv" }
foreach ($item in $manifest) {
    if ($item.jobId -notmatch '^poc-[a-f0-9]{32}$' -or $item.scenario -notmatch '^S[1-3]-[A-Za-z0-9]+$' -or $item.mode -notin @('azureFiles','blob')) {
        throw "Invalid manifest row (job/scenario/mode): $($item | ConvertTo-Json -Compress)"
    }
}
$union = foreach ($item in $manifest) {
    $job = $item.jobId.Replace("'", "''")
    $scenario = $item.scenario.Replace("'", "''")
    $mode = $item.mode.Replace("'", "''")
    "SELECT '$job' job_id,'$scenario' scenario,'$mode' copy_mode"
}
$query = @"
WITH manifest AS (
  $($union -join "`r`n  UNION ALL`r`n  ")
), mount_agg AS (
  SELECT job_id,SUM(CASE WHEN operation='smb_mount' AND success=0 THEN 1 ELSE 0 END) AS failed_mount_attempts,
    COUNT(CASE WHEN operation='smb_mount' THEN 1 END) AS mount_attempts,
    MAX(CASE WHEN operation='smb_mount' THEN 1 ELSE 0 END) AS has_smb_mount,
    MAX(CASE WHEN operation='smb_mount' AND success=1 THEN 1 ELSE 0 END) AS mount_succeeded,
    SUM(CASE WHEN operation='blob_probe' AND success=0 THEN 1 ELSE 0 END) AS failed_blob_probes
  FROM dbo.mount_metrics WHERE job_id IN (SELECT job_id FROM manifest) GROUP BY job_id
), copy_agg AS (
  SELECT job_id,SUM(COALESCE(retry_count,0)) AS copy_retries,
    SUM(CASE WHEN direction='download' AND success=1 THEN bytes ELSE 0 END) AS input_bytes,
    SUM(CASE WHEN direction='download' AND success=1 THEN 1 ELSE 0 END) AS copied_files
  FROM dbo.copy_metrics WHERE job_id IN (SELECT job_id FROM manifest) GROUP BY job_id
), metric AS (
  SELECT m.scenario,m.copy_mode,j.id,j.status,j.created_at,j.started_at,j.completed_at,
    DATEDIFF_BIG(millisecond,j.created_at,j.started_at) AS start_delay_ms,
    DATEDIFF_BIG(millisecond,j.created_at,j.completed_at) AS completion_ms,
    COALESCE(ma.failed_mount_attempts,0) AS failed_mount_attempts,
    COALESCE(ma.mount_attempts,0) AS mount_attempts,
    COALESCE(ma.has_smb_mount,0) AS has_smb_mount,
    COALESCE(ma.mount_succeeded,0) AS mount_succeeded,
    COALESCE(ma.failed_blob_probes,0) AS failed_blob_probes,
    COALESCE(ca.copy_retries,0) AS copy_retries,
    COALESCE(ca.input_bytes,0) AS input_bytes,
    COALESCE(ca.copied_files,0) AS copied_files
  FROM manifest m
  JOIN dbo.jobs j ON j.id=m.job_id
  LEFT JOIN mount_agg ma ON ma.job_id=j.id
  LEFT JOIN copy_agg ca ON ca.job_id=j.id
), ranked AS (
  SELECT *, PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY completion_ms)
      OVER (PARTITION BY scenario,copy_mode) AS p95_completion_ms
  FROM metric
), summary AS (
  SELECT scenario,copy_mode,COUNT(*) AS jobs,
    AVG(CAST(start_delay_ms AS float)) AS avg_start_delay_ms,
    MAX(p95_completion_ms) AS p95_completion_ms,
    CASE WHEN SUM(has_smb_mount)>0 THEN
      100.0*SUM(CASE WHEN has_smb_mount=1 AND mount_succeeded=0 THEN 1 ELSE 0 END)/COUNT(*) END AS mount_failure_pct,
    100.0*SUM(failed_mount_attempts)/NULLIF(SUM(mount_attempts),0) AS mount_attempt_failure_pct,
    100.0*SUM(failed_blob_probes)/COUNT(*) AS endpoint_failure_pct,
    AVG(CAST(copy_retries+CASE WHEN has_smb_mount=1 THEN IIF(mount_attempts>0,mount_attempts-1,0) ELSE 0 END AS float)) AS avg_retries,
    SUM(input_bytes) AS total_input_bytes,SUM(copied_files) AS files_copied,
    DATEDIFF_BIG(millisecond,MIN(created_at),MAX(completed_at)) AS wall_ms
  FROM ranked GROUP BY scenario,copy_mode
)
SELECT scenario,copy_mode,jobs,avg_start_delay_ms,p95_completion_ms,mount_failure_pct,avg_retries,
  CASE WHEN wall_ms>0 THEN files_copied*1000.0/wall_ms ELSE 0 END AS files_per_second,
  CASE WHEN wall_ms>0 THEN jobs*3600000.0/wall_ms ELSE 0 END AS jobs_per_hour,
  mount_attempt_failure_pct,endpoint_failure_pct,
  total_input_bytes
FROM summary ORDER BY scenario,copy_mode;
"@
$accessToken = (& az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
if ($LASTEXITCODE -ne 0 -or -not $accessToken) { throw 'Unable to obtain an Azure SQL access token; run az login from a network with private endpoint access.' }
$connection = [System.Data.SqlClient.SqlConnection]::new("Server=tcp:$SqlServerFqdn,1433;Database=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;")
$connection.AccessToken = $accessToken
try {
    $connection.Open()
    $command = $connection.CreateCommand()
    $command.CommandText = $query
    $command.CommandTimeout = 120
    $table = [System.Data.DataTable]::new()
    $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($command)
    [void]$adapter.Fill($table)
} finally {
    $connection.Dispose()
    $accessToken = $null
}
if ($table.Rows.Count -eq 0) { throw 'No completed jobs matched the manifest.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$csvPath = Join-Path $OutputDirectory 'comparison.csv'
$mdPath = Join-Path $OutputDirectory 'comparison.md'
$table | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$markdown = @(
    '# Azure Batch file I/O comparison'
    ''
    "Generated UTC: $([DateTimeOffset]::UtcNow.ToString('o'))"
    ''
    'A=`azureFiles` includes an SMB mount and file-share-to-node copy. B=`blob` downloads each input using the node managed identity; its `blob_probe` metric is endpoint/authentication readiness, not a filesystem mount.'
    ''
    '| Scenario | Mode | Jobs | Avg start delay (ms) | p95 completion (ms) | Mount failure (%) | Mount attempt failure (%) | Endpoint failure (%) | Avg retries/job | Files/sec | Jobs/hour | Input bytes |'
    '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
)
foreach ($row in $table.Rows) {
    $mountFailure = if ($row.IsNull('mount_failure_pct')) { 'N/A' } else { [math]::Round([double]$row.mount_failure_pct,2) }
    $attemptFailure = if ($row.IsNull('mount_attempt_failure_pct')) { 'N/A' } else { [math]::Round([double]$row.mount_attempt_failure_pct,2) }
    $markdown += "| $($row.scenario) | $($row.copy_mode) | $($row.jobs) | $([math]::Round([double]$row.avg_start_delay_ms,2)) | $([math]::Round([double]$row.p95_completion_ms,2)) | $mountFailure | $attemptFailure | $([math]::Round([double]$row.endpoint_failure_pct,2)) | $([math]::Round([double]$row.avg_retries,2)) | $([math]::Round([double]$row.files_per_second,3)) | $([math]::Round([double]$row.jobs_per_hour,2)) | $($row.total_input_bytes) |"
}
$markdown += @(
    ''
    'Azure Files mount failure is N/A for Blob mode: Blob mode records `blob_probe` endpoint/authentication readiness instead of an SMB mount. Mount failure is the percentage of jobs whose SMB mount never succeeded; recovered failures are represented by mount-attempt failure and retry metrics. `p95 completion` is measured from API database creation to terminal completion. Files/sec counts successfully copied input files; both CSV and this report are derived from `mount_metrics`, `copy_metrics`, `jobs`, and the manifest.'
)
$markdown | Set-Content -LiteralPath $mdPath -Encoding UTF8
Write-Host "Wrote $csvPath and $mdPath"
