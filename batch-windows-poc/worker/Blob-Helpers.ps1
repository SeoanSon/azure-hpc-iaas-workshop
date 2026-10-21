Set-StrictMode -Version Latest

function Get-MsiAccessToken {
    param([Parameter(Mandatory)][string]$Resource, [string]$ClientId)

    $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$([uri]::EscapeDataString($Resource))"
    if ($ClientId) { $uri += "&client_id=$([uri]::EscapeDataString($ClientId))" }
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSec 10
    if (-not $response.access_token) { throw 'IDENTITY_TOKEN_UNAVAILABLE' }
    return $response.access_token
}

function Get-BlobUri {
    param([string]$AccountUrl, [string]$Container, [string]$BlobName)
    $escaped = ($BlobName -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    return "$($AccountUrl.TrimEnd('/'))/$([uri]::EscapeDataString($Container))/$escaped"
}

function Get-BlobToFile {
    param(
        [Parameter(Mandatory)][string]$AccountUrl,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobName,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ClientId
    )

    $token = Get-MsiAccessToken -Resource 'https://storage.azure.com/' -ClientId $ClientId
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromHours(3)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, (Get-BlobUri $AccountUrl $Container $BlobName))
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $request.Headers.Add('x-ms-version', '2023-11-03')
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw "BLOB_DOWNLOAD_HTTP_$([int]$response.StatusCode)" }
            $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $target = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $source.CopyTo($target, 1MB) } finally { $target.Dispose(); $source.Dispose() }
            return [long]$response.Content.Headers.ContentLength
        } finally { $response.Dispose(); $request.Dispose() }
    } finally { $client.Dispose() }
}

function Upload-BlobFromFile {
    param(
        [Parameter(Mandatory)][string]$AccountUrl,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobName,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ClientId,
        [int]$BlockSizeMb = 8
    )

    $token = Get-MsiAccessToken -Resource 'https://storage.azure.com/' -ClientId $ClientId
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromHours(3)
    $uri = Get-BlobUri $AccountUrl $Container $BlobName
    $blockSize = $BlockSizeMb * 1MB
    $sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $blockIds = [System.Collections.Generic.List[string]]::new()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $buffer = [byte[]]::new($blockSize)
            $index = 0
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $rawId = 'block-{0:D8}' -f $index
                $blockId = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($rawId))
                $blockIds.Add($blockId)
                $blockUri = "$uri`?comp=block&blockid=$([uri]::EscapeDataString($blockId))"
                $bytes = if ($read -eq $buffer.Length) { $buffer } else { $buffer[0..($read - 1)] }
                $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, $blockUri)
                $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
                $request.Headers.Add('x-ms-version', '2023-11-03')
                $request.Content = [System.Net.Http.ByteArrayContent]::new($bytes)
                $response = $client.SendAsync($request).GetAwaiter().GetResult()
                try { if (-not $response.IsSuccessStatusCode) { throw "BLOB_BLOCK_HTTP_$([int]$response.StatusCode)" } }
                finally { $response.Dispose(); $request.Dispose() }
                $index++
            }
        } finally { $stream.Dispose() }

        $xml = [System.Text.StringBuilder]::new()
        [void]$xml.Append('<?xml version="1.0" encoding="utf-8"?><BlockList>')
        foreach ($id in $blockIds) { [void]$xml.Append("<Latest>$id</Latest>") }
        [void]$xml.Append('</BlockList>')
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Put, "$uri`?comp=blocklist")
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $request.Headers.Add('x-ms-version', '2023-11-03')
        $request.Headers.Add('x-ms-blob-content-type', 'application/octet-stream')
        $request.Headers.Add('x-ms-meta-sha256', $sha256)
        $request.Content = [System.Net.Http.StringContent]::new($xml.ToString(), [Text.Encoding]::UTF8, 'application/xml')
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try { if (-not $response.IsSuccessStatusCode) { throw "BLOB_COMMIT_HTTP_$([int]$response.StatusCode)" } }
        finally { $response.Dispose(); $request.Dispose() }

        $verify = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $uri)
        $verify.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $verify.Headers.Add('x-ms-version', '2023-11-03')
        $check = $client.SendAsync($verify).GetAwaiter().GetResult()
        try {
            if (-not $check.IsSuccessStatusCode -or [long]$check.Content.Headers.ContentLength -ne (Get-Item -LiteralPath $Path).Length) {
                throw 'BLOB_UPLOAD_INTEGRITY_FAILED'
            }
            $remoteHash = $check.Headers.GetValues('x-ms-meta-sha256') | Select-Object -First 1
            if ($remoteHash -ne $sha256) { throw 'BLOB_UPLOAD_HASH_MISMATCH' }
        } finally { $check.Dispose(); $verify.Dispose() }
        return @{ Bytes = (Get-Item -LiteralPath $Path).Length; Sha256 = $sha256 }
    } finally { $client.Dispose() }
}
