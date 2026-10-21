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
    if ($name -notmatch '^[A-Za-z0-9-]{1,128}$') { throw "Invalid managed identity name: $name" }
}
$schemaPath = Join-Path $PSScriptRoot '..\sql\schema.sql'
if (-not (Test-Path -LiteralPath $schemaPath)) { throw "Schema file not found: $schemaPath" }
$token = (& az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Unable to acquire an Azure SQL access token. Run az login first.' }
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
Write-Host "Schema initialized and SQL grants applied to the API and worker managed identities."
