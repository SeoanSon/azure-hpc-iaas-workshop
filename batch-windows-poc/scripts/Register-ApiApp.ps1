param([string]$DisplayName = 'Azure Batch Windows PoC API')
$ErrorActionPreference = 'Stop'
$appId = (& az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId -o tsv)
if ($LASTEXITCODE -ne 0 -or -not $appId) { throw 'Unable to create the API app registration.' }
$objectId = (& az ad app show --id $appId --query id -o tsv)
if ($LASTEXITCODE -ne 0 -or -not $objectId) { throw 'Unable to read the API app registration object ID.' }
$scopeId = [guid]::NewGuid().ToString()
& az ad app update --id $appId --identifier-uris "api://$appId" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to set the API identifier URI.' }
$body = @{
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes = @(@{
            adminConsentDisplayName = 'Access Azure Batch Windows PoC API'
            adminConsentDescription = 'Submit, monitor, cancel and read artifacts for your own PoC jobs.'
            id = $scopeId
            isEnabled = $true
            type = 'User'
            userConsentDisplayName = 'Access Azure Batch Windows PoC API'
            userConsentDescription = 'Submit, monitor, cancel and read your PoC jobs.'
            value = 'user_impersonation'
        })
    }
} | ConvertTo-Json -Depth 8 -Compress
& az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$objectId" --headers 'Content-Type=application/json' --body $body | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to expose the user_impersonation API scope. Check Microsoft Graph application permissions.' }
& az ad sp create --id $appId | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to create the API service principal.' }
Write-Output "ApiClientId=$appId"
Write-Output "ApiAudience=$appId"
Write-Output "ApiScope=api://$appId/user_impersonation"
Write-Output "AppRegistrationObjectId=$objectId"
Write-Output 'Grant admin consent and authorize an approved client application for this delegated scope before issuing tokens.'
