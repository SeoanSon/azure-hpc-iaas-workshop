param(
    [Parameter(Mandatory)][string]$ManifestCsv,
    [Parameter(Mandatory)][string]$SqlServerFqdn,
    [string]$Database = 'batchpoc',
    [string]$OutputDirectory = '.\report'
)
$ErrorActionPreference = 'Stop'
$manifest = Import-Csv -LiteralPath $ManifestCsv
if ($manifest.Count -eq 0) { throw "$ManifestCsv 파일에 작업 행이 없습니다." }
foreach ($item in $manifest) {
    if ($item.jobId -notmatch '^poc-[a-f0-9]{32}$' -or $item.scenario -notmatch '^S[1-3]-[A-Za-z0-9]+$' -or $item.mode -notin @('azureFiles','blob')) {
        throw "매니페스트 행의 작업 ID/시나리오/모드 값이 올바르지 않습니다: $($item | ConvertTo-Json -Compress)"
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
if ($LASTEXITCODE -ne 0 -or -not $accessToken) { throw 'Azure SQL 액세스 토큰을 가져오지 못했습니다. 프라이빗 엔드포인트에 접근할 수 있는 네트워크에서 az login을 실행하세요.' }
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
if ($table.Rows.Count -eq 0) { throw '매니페스트와 일치하는 완료 작업이 없습니다.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$csvPath = Join-Path $OutputDirectory 'comparison.csv'
$mdPath = Join-Path $OutputDirectory 'comparison.md'
$csvRows = foreach ($row in $table.Rows) {
    [pscustomobject]@{
        '시나리오' = $row.scenario
        '전송 방식' = $row.copy_mode
        '작업 수' = $row.jobs
        '평균 시작 지연(ms)' = $row.avg_start_delay_ms
        '완료 시간 p95(ms)' = $row.p95_completion_ms
        'Azure Files 마운트 실패율(%)' = $row.mount_failure_pct
        '마운트 시도 실패율(%)' = $row.mount_attempt_failure_pct
        'Blob 엔드포인트 실패율(%)' = $row.endpoint_failure_pct
        '작업당 평균 재시도 횟수' = $row.avg_retries
        '파일 처리량(파일/초)' = $row.files_per_second
        '작업 처리량(작업/시간)' = $row.jobs_per_hour
        '총 입력 바이트' = $row.total_input_bytes
    }
}
$csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$markdown = @(
    '# Azure Batch 파일 입출력 비교'
    ''
    "생성 시각(UTC): $([DateTimeOffset]::UtcNow.ToString('o'))"
    ''
    'A=`azureFiles`는 SMB 마운트와 파일 공유에서 노드로의 복사를 포함합니다. B=`blob`은 노드 관리 ID로 각 입력 파일을 다운로드합니다. B의 `blob_probe` 지표는 엔드포인트/인증 준비 상태이며 파일 시스템 마운트 지표가 아닙니다.'
    ''
    '| 시나리오 | 모드 | 작업 수 | 평균 시작 지연(ms) | 완료 시간 p95(ms) | 마운트 실패율(%) | 마운트 시도 실패율(%) | 엔드포인트 실패율(%) | 작업당 평균 재시도 | 파일/초 | 작업/시간 | 입력 바이트 |'
    '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|'
)
foreach ($row in $table.Rows) {
    $mountFailure = if ($row.IsNull('mount_failure_pct')) { 'N/A' } else { [math]::Round([double]$row.mount_failure_pct,2) }
    $attemptFailure = if ($row.IsNull('mount_attempt_failure_pct')) { 'N/A' } else { [math]::Round([double]$row.mount_attempt_failure_pct,2) }
    $markdown += "| $($row.scenario) | $($row.copy_mode) | $($row.jobs) | $([math]::Round([double]$row.avg_start_delay_ms,2)) | $([math]::Round([double]$row.p95_completion_ms,2)) | $mountFailure | $attemptFailure | $([math]::Round([double]$row.endpoint_failure_pct,2)) | $([math]::Round([double]$row.avg_retries,2)) | $([math]::Round([double]$row.files_per_second,3)) | $([math]::Round([double]$row.jobs_per_hour,2)) | $($row.total_input_bytes) |"
}
$markdown += @(
    ''
    'Blob 모드에는 Azure Files 마운트가 없으므로 마운트 실패율은 해당 없음(N/A)입니다. Blob 모드는 SMB 마운트 대신 `blob_probe`로 엔드포인트/인증 준비 상태를 기록합니다. 마운트 실패율은 SMB 마운트에 끝내 성공하지 못한 작업의 비율이며, 복구된 실패는 마운트 시도 실패율과 재시도 지표에 반영됩니다. `완료 시간 p95`는 API에서 작업이 생성된 시점부터 최종 완료까지의 시간입니다. 파일/초는 성공적으로 복사한 입력 파일 수를 기준으로 합니다. CSV와 보고서는 `mount_metrics`, `copy_metrics`, `jobs` 및 매니페스트에서 계산합니다.'
)
$markdown | Set-Content -LiteralPath $mdPath -Encoding UTF8
Write-Host "보고서를 저장했습니다: $csvPath 및 $mdPath"
