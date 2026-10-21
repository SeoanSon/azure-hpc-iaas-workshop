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
Write-Host "전용 Azure Files 계정 키를 Key Vault 비밀 '$SecretName'에 저장했습니다. (키 값은 표시하지 않았습니다.)"
