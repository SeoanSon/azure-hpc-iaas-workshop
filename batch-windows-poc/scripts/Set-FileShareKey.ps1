param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$FileStorageAccount,
    [Parameter(Mandatory)][string]$KeyVaultName,
    [string]$SecretName = 'azure-files-account-key'
)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Storage -ErrorAction Stop
Import-Module Az.KeyVault -ErrorAction Stop
if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }

$account = Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $FileStorageAccount
$key = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroup -Name $FileStorageAccount)[0].Value
$secureKey = ConvertTo-SecureString -String $key -AsPlainText -Force
try {
    Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName -SecretValue $secureKey | Out-Null
} finally {
    $secureKey.Dispose()
    $key = $null
}
Write-Host "Stored the dedicated Azure Files account key as Key Vault secret '$SecretName' (value not displayed)."
