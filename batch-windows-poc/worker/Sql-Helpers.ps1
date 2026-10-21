Set-StrictMode -Version Latest

function New-PocSqlConnection {
    param([Parameter(Mandatory)][string]$ConnectionString, [Parameter(Mandatory)][string]$ClientId)
    $connection = [System.Data.SqlClient.SqlConnection]::new($ConnectionString)
    $connection.AccessToken = Get-MsiAccessToken -Resource 'https://database.windows.net/' -ClientId $ClientId
    $connection.Open()
    return $connection
}

function Invoke-PocSql {
    param(
        [Parameter(Mandatory)][string]$ConnectionString,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$Query,
        [hashtable]$Parameters = @{},
        [switch]$Scalar
    )
    $connection = New-PocSqlConnection $ConnectionString $ClientId
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        foreach ($name in $Parameters.Keys) {
            $value = $Parameters[$name]
            if ($null -eq $value) { $value = [DBNull]::Value }
            [void]$command.Parameters.AddWithValue("@$name", $value)
        }
        if ($Scalar) { return $command.ExecuteScalar() }
        return $command.ExecuteNonQuery()
    } finally { $connection.Dispose() }
}
