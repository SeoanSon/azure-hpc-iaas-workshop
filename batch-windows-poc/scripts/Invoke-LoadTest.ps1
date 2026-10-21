param(
    [Parameter(Mandatory)][uri]$ApiBaseUrl,
    [Parameter(Mandatory)][string]$AccessToken,
    [Parameter(Mandatory)][string]$ExecutableBlob,
    [Parameter(Mandatory)][string]$ExecutableVersion,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string[]]$Arguments = @('{input:0}'),
    [string]$OutputCsv = '.\batch-poc-loadtest.csv',
    [int]$PollSeconds = 10,
    [int]$TimeoutMinutes = 240
)
$ErrorActionPreference = 'Stop'
$fixtures = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$headers = @{ Authorization = "Bearer $AccessToken" }
$scenarios = @(
    @{ Name = 'S1-10MB'; Count = 50 },
    @{ Name = 'S2-500MB'; Count = 50 },
    @{ Name = 'S3-2GB'; Count = 20 }
)
$results = [System.Collections.Generic.List[object]]::new()
foreach ($scenario in $scenarios) {
    $fixture = $fixtures | Where-Object scenario -eq $scenario.Name | Select-Object -First 1
    if (-not $fixture) { throw "Missing prepared fixture $($scenario.Name) in $ManifestPath" }
    $modeOrder = if ($scenario.Name -eq 'S2-500MB') { @('blob', 'azureFiles') } else { @('azureFiles', 'blob') }
    foreach ($mode in $modeOrder) {
        Write-Host "Submitting $($scenario.Name), mode=$mode, concurrency=$($scenario.Count)"
        $submitted = [System.Collections.Generic.List[object]]::new()
        $pending = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()
        for ($index = 0; $index -lt $scenario.Count; $index++) {
            $body = @{
                executableBlob = $ExecutableBlob
                executableVersion = $ExecutableVersion
                copyMode = $mode
                inputs = @(@{ blobName = $fixture.blobName; expectedBytes = [long]$fixture.bytes; expectedSha256 = $fixture.sha256 })
                arguments = $Arguments
                timeoutSeconds = 3600
            } | ConvertTo-Json -Depth 6 -Compress
            $created = [DateTimeOffset]::UtcNow
            $pending.Add((Start-Job -ScriptBlock {
                param($Url, $Auth, $Json, $At)
                try {
                    $response = Invoke-RestMethod -Method Post -Uri "$($Url.TrimEnd('/'))/jobs" -Headers $Auth -ContentType 'application/json' -Body $Json
                    [pscustomobject]@{ id = $response.id; submittedAt = $At; error = $null }
                } catch { [pscustomobject]@{ id = $null; submittedAt = $At; error = $_.Exception.Message } }
            } -ArgumentList $ApiBaseUrl.AbsoluteUri, $headers, $body, $created))
            if ($pending.Count -ge 10) {
                $completed = Wait-Job -Job $pending -Any
                $submitted.AddRange([object[]](Receive-Job -Job $completed))
                Remove-Job -Job $completed -Force
                [void]$pending.Remove($completed)
            }
        }
        while ($pending.Count -gt 0) {
            $completed = Wait-Job -Job $pending -Any
            $submitted.AddRange([object[]](Receive-Job -Job $completed))
            Remove-Job -Job $completed -Force
            [void]$pending.Remove($completed)
        }
        $failedSubmit = @($submitted | Where-Object { -not $_.id })
        if ($failedSubmit.Count -gt 0) { throw "$($failedSubmit.Count) POST /jobs requests failed. First error: $($failedSubmit[0].error)" }
        foreach ($job in $submitted) {
            $results.Add([pscustomobject]@{
                scenario = $scenario.Name
                concurrency = $scenario.Count
                mode = $mode
                jobId = $job.id
                submittedAtUtc = $job.submittedAt.ToUniversalTime().ToString('o')
            })
        }
        $results | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
        $deadline = [DateTimeOffset]::UtcNow.AddMinutes($TimeoutMinutes)
        $remaining = @($submitted | ForEach-Object { $_.id })
        while ($remaining.Count -gt 0 -and [DateTimeOffset]::UtcNow -lt $deadline) {
            $stillRunning = [System.Collections.Generic.List[string]]::new()
            foreach ($jobId in $remaining) {
                $state = Invoke-RestMethod -Method Get -Uri "$($ApiBaseUrl.AbsoluteUri.TrimEnd('/'))/jobs/$jobId" -Headers $headers
                if ($state.status -in @('queued','running')) { $stillRunning.Add($jobId) }
                elseif ($state.status -notin @('succeeded')) { throw "Job $jobId ended with status=$($state.status), error=$($state.errorCode)" }
            }
            $remaining = @($stillRunning)
            if ($remaining.Count -gt 0) { Start-Sleep -Seconds $PollSeconds }
        }
        if ($remaining.Count -gt 0) { throw "Timed out waiting for $($remaining.Count) jobs in $($scenario.Name)/$mode. Manifest has been saved only after all scenarios." }
    }
}
$results | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
Write-Host "Completed all six mode/scenario runs. Job manifest: $((Resolve-Path $OutputCsv).Path)"
