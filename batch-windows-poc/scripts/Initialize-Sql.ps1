param(
    [Parameter(Mandatory)][string]$ServerFqdn,
    [string]$Database = 'batchpoc',
    [Parameter(Mandatory)][string]$ApiIdentityName,
    [Parameter(Mandatory)][guid]$ApiPrincipalId,
    [Parameter(Mandatory)][string]$WorkerIdentityName,
    [Parameter(Mandatory)][guid]$WorkerPrincipalId
)
$ErrorActionPreference = 'Stop'
foreach ($name in @($ApiIdentityName, $WorkerIdentityName)) {
    if ($name -notmatch '^[A-Za-z0-9-]{1,128}$') { throw "관리 ID 이름이 올바르지 않습니다: $name" }
}
$schemaPath = Join-Path $PSScriptRoot '..\sql\schema.sql'
if (-not (Test-Path -LiteralPath $schemaPath)) { throw "스키마 파일을 찾을 수 없습니다: $schemaPath" }
$token = (& az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Azure SQL 액세스 토큰을 가져오지 못했습니다. 먼저 az login을 실행하세요.' }
$connection = [System.Data.SqlClient.SqlConnection]::new("Server=tcp:$ServerFqdn,1433;Database=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;")
$connection.AccessToken = $token
try {
    $connection.Open()
    $schema = Get-Content -LiteralPath $schemaPath -Raw
    $command = $connection.CreateCommand()
    $command.CommandText = $schema
    $command.CommandTimeout = 120
    [void]$command.ExecuteNonQuery()

    $apiUser = $ApiIdentityName.Replace(']', ']]')
    $workerUser = $WorkerIdentityName.Replace(']', ']]')
    $grantSql = @"
CREATE USER [$apiUser] FROM EXTERNAL PROVIDER WITH OBJECT_ID='$ApiPrincipalId';
ALTER ROLE poc_api_role ADD MEMBER [$apiUser];
CREATE USER [$workerUser] FROM EXTERNAL PROVIDER WITH OBJECT_ID='$WorkerPrincipalId';
ALTER ROLE poc_worker_role ADD MEMBER [$workerUser];
"@
    $command.CommandText = $grantSql
    [void]$command.ExecuteNonQuery()
} finally {
    $connection.Dispose()
    $token = $null
}
Write-Host '스키마를 초기화하고 API 및 작업자 관리 ID에 SQL 권한을 부여했습니다.'
