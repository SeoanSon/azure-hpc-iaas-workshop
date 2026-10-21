# Azure Batch Windows 파일 입출력 PoC

Azure 내부에서만 동작하는 Windows 작업 실행기와 파일 준비 방식 비교용 PoC입니다. API, Azure Batch, Blob Storage, Azure Files, SQL, Key Vault는 프라이빗 엔드포인트를 통해 연결하며 Batch 노드에는 공용 IP를 할당하지 않습니다. API 사용자는 Entra ID의 `user_impersonation` 위임 범위를 포함한 액세스 토큰으로 인증해야 합니다. 각 사용자는 본인이 제출한 작업과 아티팩트만 조회할 수 있습니다.

## 구성 및 주요 Azure 제약

- **헤드/API:** Windows App Service에서 실행하는 .NET 8 최소 API입니다. 요청을 검증하고 Azure SQL에 저장한 뒤 Batch 작업을 제출합니다. 작업 상태를 동기화하고 아티팩트마다 읽기 전용 사용자 위임 SAS URL을 짧은 만료 시간으로 발급합니다.
- **컴퓨팅:** Windows Server 2022 Azure Batch 풀은 전용 노드를 0~50개로 자동 확장하며 노드당 작업 슬롯은 1개입니다. 풀에는 사용자 할당 관리 ID(UAMI)를 연결합니다. API는 별도의 UAMI로 Batch 서비스 OAuth(`https://batch.core.windows.net/.default`)를 사용하고 Batch 계정은 Entra ID 인증만 허용합니다.
- **입력/출력:** 풀 관리 ID에는 `inputs` 및 `jobpayloads` 컨테이너 Blob 읽기 권한, `outputs` 컨테이너 Blob 기여자 권한과 PoC 데이터베이스의 제한된 SQL 테이블 권한만 부여합니다. 작업 매니페스트는 비공개 `jobpayloads` 컨테이너에서 가져오므로 사용자 인자나 긴 JSON을 Batch 명령줄에 넣지 않습니다.
- **방식 A(`azureFiles`):** Windows SMB 3.x 클라이언트로 Azure Files 공유를 연결하고 같은 상대 경로의 입력 파일을 노드 로컬 저장소로 복사합니다. TCP 445와 프라이빗 DNS/네트워크 연결이 허용되어야 하는, Windows에서 지원되는 Azure Files 경로입니다. Azure Files의 ID 기반 SMB 인증에는 AD DS/Entra Kerberos 도메인에 가입한 클라이언트와 ID/파일 ACL 구성이 필요합니다. 배포 가능한 PoC는 전용 Key Vault에 저장한 **파일 전용 계정 키**를 사용합니다. 작업자 UAMI가 실행 중 비밀을 가져오며 키를 Batch 명령줄이나 API 페이로드에 넣지 않습니다. 마운트 하위 프로세스에는 감시 제한 시간과 재시도를 적용합니다. 이 스토리지 계정을 다른 용도로 재사용하지 마세요.
- **방식 B(`blob`):** 각 작업이 풀 UAMI를 사용해 프라이빗 Blob Storage에서 입력을 다운로드합니다. 파일 시스템 마운트 대신 인증된 Blob 엔드포인트 연결 상태를 확인합니다. 따라서 보고서에서 Blob 방식의 SMB 마운트 실패율은 `N/A`이고 Blob 엔드포인트 실패율은 별도로 표시합니다.
- **캐시/무결성:** 실행 파일은 Batch 노드 공유 디렉터리에 캐시합니다. 작업별로 Blob ETag, 지정 버전 및 캐시된 파일의 SHA-256을 비교해 변경된 경우에만 다시 다운로드합니다. 입력 파일은 매 작업마다 복사하고, 선택한 크기/SHA-256을 검증하며 처리 시간을 측정합니다. 아티팩트는 최대 4개씩 병렬 업로드하고 블록 Blob, SHA-256 메타데이터, 업로드 후 길이/해시 검증을 사용합니다.
- **상태/지표:** `sql/schema.sql`에서 `jobs`, `job_inputs`, `job_runs`, `job_artifacts`, `mount_metrics`, `copy_metrics`, `job_events`, `node_cache` 테이블을 생성합니다. API와 노드 ID를 각각 SQL 외부 사용자로 등록하고 테이블별 역할을 다르게 부여합니다.

모든 PoC 엔드포인트와 리소스는 프라이빗 네트워크에서만 접근할 수 있습니다. 운영자와 API 사용자는 프라이빗 DNS 영역을 연결/확인할 수 있는 VNet 내부 호스트 또는 승인된 VPN/ExpressRoute 연결을 사용해야 합니다. 공용 인그레스 대체 경로는 제공하지 않습니다.

## 파일 구성

```text
batch-windows-poc/
  README.md
  api/BatchPoc.Api/
    BatchPoc.Api.csproj
    Program.cs
    Contracts.cs
    Services/
      AzureCredentialFactory.cs
      BatchRestClient.cs
      JobMonitor.cs
      RuntimeOptions.cs
      SqlStore.cs
  infra/main.bicep
  sql/schema.sql
  worker/
    Blob-Helpers.ps1
    Copy-JobInputs.ps1
    Invoke-BatchJob.ps1
    Invoke-Exe.ps1
    Mount-AzureFiles.ps1
    Sql-Helpers.ps1
    Upload-JobArtifacts.ps1
    Upload-OneArtifact.ps1
  scripts/
    Initialize-Sql.ps1
    Invoke-LoadTest.ps1
    New-ComparisonReport.ps1
    Prepare-TestData.ps1
    Register-ApiApp.ps1
    Set-FileShareKey.ps1
  samples/CopyProbe/
    CopyProbe.csproj
    Program.cs
```

## 배포 전에 준비할 항목

1. Azure 구독 ID와 리소스 그룹, Korea Central 리전의 서비스 할당량/용량을 확인하세요. 기본 Batch VM SKU는 `Standard_D4as_v5`입니다. 전용 노드 수, 프라이빗 엔드포인트, Premium App Service Plan의 한도도 확인해야 합니다.
2. Entra 테넌트 관리자가 API 앱 등록을 만들고 `user_impersonation` 범위를 공개한 다음 동의해야 합니다. `scripts/Register-ApiApp.ps1`을 실행하고 출력된 `ApiAudience`(앱/클라이언트 ID)를 Bicep의 `apiAudience` 매개 변수로 전달하세요. 호출자 앱에 위임 동의를 부여하세요. API는 클라이언트 암호를 사용하지 않습니다.
3. Azure SQL 논리 서버에 권한이 있는 Entra SQL 관리자 **그룹** 이름과 개체 ID(`sqlAdminLogin`, `sqlAdminObjectId`)를 준비하세요.
4. SQL/Key Vault 초기 설정 및 API 배포를 수행할 VNet 연결 Windows 관리자 호스트가 필요합니다. 호스트에 `az login`, Az PowerShell 모듈, Azure CLI, .NET 8 SDK와 리소스/RBAC 할당 권한을 준비하세요.
5. Korea Central에서 Batch Windows 이미지, Batch Private Link, SQL 서버리스 SKU, 선택한 VM 제품군, App Service P1v3, Azure Files 프라이빗 엔드포인트를 사용할 수 있는지 확인하세요.
6. 실제 Windows EXE와 입력 인자 형식, 런타임/종속성 요구사항을 준비하세요. 포함된 `CopyProbe.exe`는 자체 포함형 검증용 예제일 뿐입니다.

## 배포(PowerShell)

인증된 배포 셸에서 이 디렉터리를 기준으로 실행하세요. 데이터 영역 초기 설정과 프라이빗 배포 엔드포인트에 접근해야 하므로 VNet 연결 호스트에서 배포하는 것이 좋습니다.

```powershell
$ErrorActionPreference = 'Stop'
az login
$subscriptionId = '<구독_ID>'
$resourceGroup = 'rg-batch-windows-poc'
$region = 'koreacentral'
$sqlAdminLogin = '<ENTRA_SQL_관리자_그룹_이름>'
$sqlAdminObjectId = '<ENTRA_SQL_관리자_그룹_개체_ID>'
$apiAudience = '<Register-ApiApp에서_출력된_API_앱_클라이언트_ID>'
az account set --subscription $subscriptionId
az group create --name $resourceGroup --location $region
az deployment group create --name batch-windows-poc --resource-group $resourceGroup --template-file .\infra\main.bicep --parameters namePrefix=hpcbatch location=$region sqlAdminLogin=$sqlAdminLogin sqlAdminObjectId=$sqlAdminObjectId apiAudience=$apiAudience
$outputs = az deployment group show --resource-group $resourceGroup --name batch-windows-poc --query properties.outputs -o json | ConvertFrom-Json
```

템플릿은 프라이빗 네트워크, 격리된 스토리지 계정 2개(Blob 및 Files), 프라이빗 엔드포인트/DNS, SQL 데이터베이스, 프라이빗 Key Vault, Batch 계정/풀, UAMI, 역할 할당 및 Windows App Service를 만듭니다. Bicep의 리전 기본값도 `koreacentral`이며 위 배포 명령에서 이를 명시적으로 지정합니다. Batch 풀의 자동 확장 수식은 전용 노드 50개로 제한합니다. `batchMaxNodes` 또는 `batchVmSize`를 변경하려면 먼저 할당량과 해당 리전의 용량을 확인하세요.

Azure RBAC 전파에는 몇 분이 걸릴 수 있습니다. 배포 출력으로 범위가 제한된 초기 설정 역할을 운영자에게 부여하세요. 구독/리소스 그룹 관리자가 다음 명령을 실행할 수 있습니다.

```powershell
$me = az ad signed-in-user show --query id -o tsv
$rgId = az group show --name $resourceGroup --query id -o tsv
$blobId = "$rgId/providers/Microsoft.Storage/storageAccounts/$($outputs.blobStorageAccountName.value)"
$fileId = "$rgId/providers/Microsoft.Storage/storageAccounts/$($outputs.fileStorageAccountName.value)"
$vaultId = "$rgId/providers/Microsoft.KeyVault/vaults/$($outputs.keyVaultName.value)"
az role assignment create --assignee $me --role 'Storage Blob Data Contributor' --scope "$blobId/blobServices/default/containers/inputs"
az role assignment create --assignee $me --role 'Storage Blob Data Contributor' --scope "$blobId/blobServices/default/containers/bootstrap"
az role assignment create --assignee $me --role 'Storage Account Key Operator Service Role' --scope $fileId
az role assignment create --assignee $me --role 'Key Vault Secrets Officer' --scope $vaultId
```

VNet 연결 호스트에서 SQL을 초기화하고 전용 Azure Files 키를 등록합니다. 스크립트는 Entra 토큰을 메모리에서만 사용하며 토큰이나 스토리지 키를 출력하지 않습니다.

```powershell
.\scripts\Initialize-Sql.ps1 -ServerFqdn $outputs.sqlServerFqdn.value -Database $outputs.sqlDatabaseName.value -ApiIdentityName $outputs.apiIdentityName.value -ApiPrincipalId $outputs.apiIdentityPrincipalId.value -WorkerIdentityName $outputs.workerIdentityName.value -WorkerPrincipalId $outputs.workerIdentityPrincipalId.value
.\scripts\Set-FileShareKey.ps1 -ResourceGroup $resourceGroup -FileStorageAccount $outputs.fileStorageAccountName.value -KeyVaultName $outputs.keyVaultName.value
```

테스트 실행 파일을 Windows x64 자체 포함형으로 빌드한 뒤 입력 컨테이너와 작업자 스크립트를 업로드합니다. `inputs` 컨테이너에는 실행 파일도 저장하며, `bootstrap` 컨테이너에는 Batch가 만료 시간이 짧은 읽기 전용 사용자 위임 SAS URL로 가져올 스크립트를 저장합니다. 작업 페이로드는 API가 비공개로 올리며 Batch ID가 관리 ID로 읽습니다.

```powershell
dotnet publish .\samples\CopyProbe\CopyProbe.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o .\artifacts\copyprobe
$exe = Resolve-Path .\artifacts\copyprobe\CopyProbe.exe
az storage blob upload --auth-mode login --account-name $outputs.blobStorageAccountName.value --container-name inputs --name apps/CopyProbe.exe --file $exe --overwrite
az storage blob upload-batch --auth-mode login --account-name $outputs.blobStorageAccountName.value --destination bootstrap --source .\worker --overwrite
```

프라이빗 엔드포인트가 확인되는 VNet 연결 Windows 호스트에서 API를 게시합니다.

```powershell
dotnet publish .\api\BatchPoc.Api\BatchPoc.Api.csproj -c Release -o .\artifacts\api
Compress-Archive -Path .\artifacts\api\* -DestinationPath .\artifacts\api.zip -Force
$apiName = az resource list --resource-group $resourceGroup --resource-type Microsoft.Web/sites --query '[0].name' -o tsv
az webapp deploy --resource-group $resourceGroup --name $apiName --src-path .\artifacts\api.zip --type zip
```

`api://<API_앱_클라이언트_ID>/user_impersonation` 범위에 동의한 Entra 클라이언트 앱에서 토큰을 가져옵니다.

```powershell
$apiClientId = '<API_앱_클라이언트_ID>'
$token = az account get-access-token --scope "api://$apiClientId/user_impersonation" --query accessToken -o tsv
$apiUrl = $outputs.apiUrl.value
Invoke-RestMethod -Method Get -Uri "$apiUrl/healthz"
```

`GET /healthz`는 프라이빗 네트워크에서만 접근 가능하고 인증은 요구하지 않습니다. 모든 작업 API는 위임 범위를 요구하며 작업/아티팩트 조회는 호출자의 Entra `oid`로 제한됩니다.

## 부하 테스트 및 보고서 생성

Blob과 Azure Files에 동일한 테스트 파일(10 MiB, 500 MiB, 2 GiB)을 생성합니다. 파일은 결정적인 바이트 패턴으로 채워집니다. 업로드 시간이 오래 걸리고 스토리지/트랜잭션/네트워크 비용이 발생할 수 있습니다.

```powershell
.\scripts\Prepare-TestData.ps1 -ResourceGroup $resourceGroup -BlobStorageAccount $outputs.blobStorageAccountName.value -FileStorageAccount $outputs.fileStorageAccountName.value -OutputManifest .\artifacts\test-data-manifest.json
.\scripts\Invoke-LoadTest.ps1 -ApiBaseUrl $apiUrl -AccessToken $token -ExecutableBlob apps/CopyProbe.exe -ExecutableVersion v1 -ManifestPath .\artifacts\test-data-manifest.json -Arguments @('{input:0}') -OutputCsv .\artifacts\jobs.csv
.\scripts\New-ComparisonReport.ps1 -ManifestCsv .\artifacts\jobs.csv -SqlServerFqdn $outputs.sqlServerFqdn.value -Database $outputs.sqlDatabaseName.value -OutputDirectory .\artifacts\report
```

부하 스크립트는 두 방식이 서로 간섭하지 않도록 시나리오별로 비교 실행을 순차 진행합니다. 중형 시나리오에서는 실행 순서를 뒤집어 순서 편향을 줄입니다. S1/S2는 각각 방식별 50개 작업, S3는 방식별 20개 작업을 제출합니다. 보고서는 평균 API 제출-작업 시작 지연, API 작업 생성부터 완료까지의 p95, SMB 마운트 실패율(Blob은 해당 없음), 마운트 시도 실패율, Blob 엔드포인트 준비 실패율, 작업당 평균 재시도, 파일/초, 작업/시간을 제공합니다. 원본 SQL 테이블에는 작업/파일별 시각, 각 시도 결과, 바이트 수, 해시 및 오류 코드가 보존됩니다.

### API 호출 예시

```powershell
$headers = @{ Authorization = "Bearer $token" }
$body = @{
  executableBlob = 'apps/CopyProbe.exe'
  executableVersion = 'v1'
  copyMode = 'blob' # 또는 'azureFiles'
  inputs = @(@{ blobName = 'S1-10MB/input.bin'; expectedBytes = 10485760; expectedSha256 = '<64자리_SHA256_16진수>' })
  arguments = @('{input:0}')
  timeoutSeconds = 3600
} | ConvertTo-Json -Depth 6
$job = Invoke-RestMethod -Method Post -Uri "$apiUrl/jobs" -Headers $headers -ContentType 'application/json' -Body $body
Invoke-RestMethod -Method Get -Uri "$apiUrl/jobs/$($job.id)" -Headers $headers
Invoke-RestMethod -Method Get -Uri "$apiUrl/jobs/$($job.id)/artifacts" -Headers $headers
Invoke-RestMethod -Method Post -Uri "$apiUrl/jobs/$($job.id)/cancel" -Headers $headers
```

인자는 명령 문자열이 아니라 JSON 배열입니다. `{input:0}`, `{input:1}` 등은 해당 순서 입력 파일의 노드 로컬 경로로 바뀝니다. 나머지 인자는 Windows 명령줄 규칙에 따라 인용 처리되며 셸 확장은 수행하지 않습니다.

## 제한 사항 및 Azure에서 추가로 검증할 항목

- Azure Files ID 기반 SMB(AD DS/Entra Kerberos)는 구성하지 않았습니다. 기존 디렉터리/도메인 가입 설계와 파일 ACL 정책이 필요합니다. PoC는 실용적인 Windows SMB 연결을 위해 Key Vault의 전용 계정 키를 사용합니다. 운영 환경에서는 도메인 통합 후 ID 기반 인증으로 전환하세요.
- SQL 외부 사용자와 테이블 권한은 Bicep에서 SQL 관리자 자격 증명 없이 만들 수 없으므로 배포 후 `Initialize-Sql.ps1`로 설정합니다.
- 대상 구독/리전에서 Batch 프라이빗 엔드포인트 그룹 ID와 Batch Private Link 지원 여부, 공용 네트워크 접근 차단, 프라이빗 DNS, 풀의 공용 IP 제거, 이미지/노드 에이전트 호환성, 할당량/용량, Azure Files SMB 연결성 및 작업 UAMI 토큰 발급을 확인해야 합니다. 이 저장소 변경 과정에서는 Azure 구독 배포를 실행하지 않았습니다.
- 프라이빗 앱 배포, SQL 초기화, Key Vault 비밀 등록 및 테스트에는 VNet 연결 관리자 호스트가 필요합니다. 공용 CLI 환경에서는 프라이빗 데이터 엔드포인트에 접근할 수 없습니다.
- 부하 테스트는 순수 NIC/SMB 마이크로벤치마크가 아니라 애플리케이션의 파일 준비와 실행 시간을 비교합니다. VM SKU, 노드 수/콜드 스타트, 스토리지 계층, 리전, 파일 캐시 상태 및 실행 순서가 결과에 영향을 줍니다. 반복 측정 시 매니페스트와 원시 지표를 보존하세요.
- 요청한 상태 목록에 `cancelled`가 없으므로 취소는 `error_code='CANCELLED'`인 최종 `failed` 상태로 기록합니다. `mount_failed`와 `upload_failed`는 별도 최종 상태입니다.
- 예제 EXE는 파일 읽기 벤치마크이며 실제 업무 프로그램이 아닙니다. 풀을 사용하기 전에 실제 EXE 실행 시간, 인자, 출력 파일 패턴, 파일 크기, VM SKU, 할당량 및 리전을 확정하세요.
