param([string]$DisplayName = 'Azure Batch Windows PoC API')
$ErrorActionPreference = 'Stop'
$appId = (& az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId -o tsv)
if ($LASTEXITCODE -ne 0 -or -not $appId) { throw 'API 앱 등록을 만들지 못했습니다.' }
$objectId = (& az ad app show --id $appId --query id -o tsv)
if ($LASTEXITCODE -ne 0 -or -not $objectId) { throw 'API 앱 등록의 개체 ID를 가져오지 못했습니다.' }
$scopeId = [guid]::NewGuid().ToString()
& az ad app update --id $appId --identifier-uris "api://$appId" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'API 식별자 URI를 설정하지 못했습니다.' }
$body = @{
    api = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes = @(@{
            adminConsentDisplayName = 'Azure Batch Windows PoC API 액세스'
            adminConsentDescription = '자신의 PoC 작업을 제출하고, 상태를 확인하고, 취소하고, 아티팩트를 조회합니다.'
            id = $scopeId
            isEnabled = $true
            type = 'User'
            userConsentDisplayName = 'Azure Batch Windows PoC API 액세스'
            userConsentDescription = 'PoC 작업을 제출하고, 상태를 확인하고, 취소하고, 아티팩트를 조회합니다.'
            value = 'user_impersonation'
        })
    }
} | ConvertTo-Json -Depth 8 -Compress
& az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$objectId" --headers 'Content-Type=application/json' --body $body | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'user_impersonation API 범위를 공개하지 못했습니다. Microsoft Graph 애플리케이션 권한을 확인하세요.' }
& az ad sp create --id $appId | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'API 서비스 주체를 만들지 못했습니다.' }
Write-Output "ApiClientId=$appId"
Write-Output "ApiAudience=$appId"
Write-Output "ApiScope=api://$appId/user_impersonation"
Write-Output "AppRegistrationObjectId=$objectId"
Write-Output '토큰을 발급하기 전에 관리자 동의를 부여하고 승인된 클라이언트 앱에 이 위임 범위를 허용하세요.'
