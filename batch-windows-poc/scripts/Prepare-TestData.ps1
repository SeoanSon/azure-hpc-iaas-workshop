param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$BlobStorageAccount,
    [Parameter(Mandatory)][string]$FileStorageAccount,
    [string]$InputContainer = 'inputs',
    [string]$FileShare = 'inputs',
    [string]$OutputManifest = '.\test-data-manifest.json'
)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Storage -ErrorAction Stop
if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }

$blobContext = New-AzStorageContext -StorageAccountName $BlobStorageAccount -UseConnectedAccount
$fileKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroup -Name $FileStorageAccount)[0].Value
$fileContext = New-AzStorageContext -StorageAccountName $FileStorageAccount -StorageAccountKey $fileKey
$scratch = Join-Path ([IO.Path]::GetTempPath()) ("batch-poc-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$sizes = @(
    @{ Name = 'S1-10MB'; Bytes = 10MB },
    @{ Name = 'S2-500MB'; Bytes = 500MB },
    @{ Name = 'S3-2GB'; Bytes = 2GB }
)
$manifest = foreach ($scenario in $sizes) {
    $path = Join-Path $scratch 'input.bin'
    $stream = [IO.File]::Open($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $buffer = [byte[]]::new(1MB)
        for ($index = 0; $index -lt $buffer.Length; $index++) { $buffer[$index] = 0x5A }
        $remaining = [long]$scenario.Bytes
        while ($remaining -gt 0) {
            $count = [int][Math]::Min($buffer.Length, $remaining)
            $stream.Write($buffer, 0, $count)
            $remaining -= $count
        }
    } finally { $stream.Dispose() }
    $blobName = "$($scenario.Name)-input.bin"
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-AzStorageBlobContent -File $path -Container $InputContainer -Blob $blobName -Context $blobContext -Force | Out-Null
    Set-AzStorageFileContent -ShareName $FileShare -Source $path -Path $blobName -Context $fileContext -Force | Out-Null
    [pscustomobject]@{ scenario = $scenario.Name; bytes = [long]$scenario.Bytes; blobName = $blobName; sha256 = $hash }
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputManifest -Encoding UTF8
Remove-Item -LiteralPath $scratch -Recurse -Force
$fileKey = $null
Write-Host "Input fixtures uploaded identically to Blob and Azure Files. Manifest: $((Resolve-Path $OutputManifest).Path)"
