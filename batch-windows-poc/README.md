# Azure Batch Windows I/O PoC

An Azure-only Windows job runner and repeatable A/B data-staging benchmark. The API is private (App Service private endpoint), Batch nodes have no public IPs, and Blob, Azure Files, SQL, Key Vault, and Batch endpoints use private endpoints. API callers need an Entra access token with the delegated `user_impersonation` scope; jobs are isolated to the submitting user's `oid`.

## Design and important Azure constraints

- **Head:** .NET 8 minimal API hosted on Windows App Service. It validates the request, persists it in Azure SQL, submits one Azure Batch task, reconciles task state, and returns short-lived user-delegation SAS URLs scoped read-only to each artifact.
- **Compute:** Azure Batch Windows Server 2022 pool, autoscaled 0–50 dedicated nodes, one task slot per node. The pool has a user-assigned managed identity. The API uses its own UAMI and Entra OAuth for the Batch service (`https://batch.core.windows.net/.default`); the Batch account is configured for AAD-only authentication.
- **Input and output:** the pool identity has Blob Data Reader on `inputs` and `jobpayloads`, Blob Data Contributor on `outputs`, and SQL access only to the PoC database's restricted table roles. It retrieves its job manifest from the private `jobpayloads` container rather than embedding user arguments or long JSON on a command line.
- **Mode A (`azureFiles`):** uses the Windows SMB 3.x client to map the Azure Files share from the Batch task's Windows identity and copies the same relative input path to node-local task storage. This is a supported Azure Files/Windows-client path when TCP 445 and private DNS/network connectivity work. Since Azure Files SMB identity authentication requires an AD DS/Entra Kerberos domain-joined client and appropriate identity/file ACL configuration, this deployable PoC uses a **separate, files-only account key** stored in a dedicated Key Vault. The worker UAMI reads that secret at runtime; the key is not in the Batch command line or API payload. The mount subprocess is watchdog-timed and retried. Do not reuse this account for unrelated data.
- **Mode B (`blob`):** each job downloads inputs from private Blob Storage using the pool UAMI. It performs an authenticated Blob endpoint probe, not a filesystem mount. The report therefore shows SMB mount failure as N/A for Blob mode and reports the Blob endpoint failure percentage separately.
- **Caching and integrity:** the executable is cached under the Batch node shared directory. Each job checks Blob ETag, supplied version, and the cached file's SHA-256; content is downloaded only after a mismatch. Input files are copied on each job, checked against optional expected size/SHA-256 values, and timed. Artifact files upload concurrently in bounded groups of four with block-blob upload, SHA-256 metadata, and post-upload length/hash verification.
- **State and metrics:** `jobs`, `job_inputs`, `job_runs`, `job_artifacts`, `mount_metrics`, `copy_metrics`, `job_events`, and `node_cache` are created by `sql/schema.sql`. The API and node identities are created as separate SQL external users and receive different table-level roles.

All POC endpoints/resources are private-network accessible only. An operator or client must run from a VNet-connected host or an approved VPN/ExpressRoute-connected network with the private DNS zones linked/resolvable. There is no public ingress fallback.

## File tree

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

## TODOs before deployment

1. Azure subscription, resource group, region, and service quotas/capacity for the Batch VM SKU (`Standard_D4as_v5` by default), Batch dedicated nodes, private endpoints, and Premium App Service Plan.
2. An Entra tenant admin/operator to create the API app registration, expose and consent `user_impersonation`, and approve a caller application. Run `scripts/Register-ApiApp.ps1`; pass its `ApiAudience` (the app/client ID) to the Bicep `apiAudience` parameter. Grant the caller delegated consent. The API itself does not use a client secret.
3. A SQL Entra administrator **group** name and object ID (`sqlAdminLogin`, `sqlAdminObjectId`) authorized on the subscription's Azure SQL logical server.
4. A VNet-connected Windows admin host for SQL/Key Vault bootstrap and API deployment; local `az login`, Az PowerShell modules, Azure CLI, .NET 8 SDK, and permission to create resources/RBAC assignments.
5. Confirm the region supports the requested Batch Windows image, Batch Private Link, SQL serverless SKU, selected VM family, App Service P1v3, and Azure Files private endpoint.
6. A Windows EXE plus its expected input argument format and any runtime/dependency requirements. The included `CopyProbe.exe` is only a self-contained verification workload.

## Deployment (PowerShell)

Run from this directory in an authenticated deployment shell. Deploy from a VNet-connected machine when possible because the data-plane bootstrap and deployment endpoint are private.

```powershell
$ErrorActionPreference = 'Stop'
az login
$subscriptionId = '<SUBSCRIPTION_ID>'
$resourceGroup = 'rg-batch-windows-poc'
$region = 'eastus'
$sqlAdminLogin = '<ENTRA_SQL_ADMIN_GROUP_NAME>'
$sqlAdminObjectId = '<ENTRA_SQL_ADMIN_GROUP_OBJECT_ID>'
$apiAudience = '<API_APP_CLIENT_ID_FROM_Register-ApiApp>'
az account set --subscription $subscriptionId
az group create --name $resourceGroup --location $region
az deployment group create --name batch-windows-poc --resource-group $resourceGroup --template-file .\infra\main.bicep --parameters namePrefix=hpcbatch location=$region sqlAdminLogin=$sqlAdminLogin sqlAdminObjectId=$sqlAdminObjectId apiAudience=$apiAudience
$outputs = az deployment group show --resource-group $resourceGroup --name batch-windows-poc --query properties.outputs -o json | ConvertFrom-Json
```

The deployment creates the private network, two isolated storage accounts (Blob and Files), private endpoints/DNS, SQL database, private Key Vault, Batch account/pool, UAMIs, role assignments, and Windows App Service. The Batch pool autoscale formula caps dedicated nodes at 50; tune `batchMaxNodes`/`batchVmSize` only after checking quota and regional capacity.

Azure RBAC propagation can take several minutes. Use deployment outputs to grant the deploying operator the scoped setup roles (commands may be run by a subscription/resource-group administrator):

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

Initialize SQL and set the isolated Azure Files key from the VNet-connected host. These scripts obtain Entra tokens in memory and do not print the token or storage key.

```powershell
.\scripts\Initialize-Sql.ps1 -ServerFqdn $outputs.sqlServerFqdn.value -Database $outputs.sqlDatabaseName.value -ApiIdentityName $outputs.apiIdentityName.value -ApiPrincipalId $outputs.apiIdentityPrincipalId.value -WorkerIdentityName $outputs.workerIdentityName.value -WorkerPrincipalId $outputs.workerIdentityPrincipalId.value
.\scripts\Set-FileShareKey.ps1 -ResourceGroup $resourceGroup -FileStorageAccount $outputs.fileStorageAccountName.value -KeyVaultName $outputs.keyVaultName.value
```

Build the test executable self-contained for Windows x64, then upload it and all worker scripts. The `inputs` container also stores the executable; the `bootstrap` container stores scripts that Batch fetches using short-lived read-only user-delegation SAS URLs. Job payloads are uploaded privately by the API and read by the Batch identity using MI.

```powershell
dotnet publish .\samples\CopyProbe\CopyProbe.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o .\artifacts\copyprobe
$exe = Resolve-Path .\artifacts\copyprobe\CopyProbe.exe
az storage blob upload --auth-mode login --account-name $outputs.blobStorageAccountName.value --container-name inputs --name apps/CopyProbe.exe --file $exe --overwrite
az storage blob upload-batch --auth-mode login --account-name $outputs.blobStorageAccountName.value --destination bootstrap --source .\worker --overwrite
```

Deploy the API (from a VNet-connected Windows host with the private endpoint resolving):

```powershell
dotnet publish .\api\BatchPoc.Api\BatchPoc.Api.csproj -c Release -o .\artifacts\api
Compress-Archive -Path .\artifacts\api\* -DestinationPath .\artifacts\api.zip -Force
$apiName = az resource list --resource-group $resourceGroup --resource-type Microsoft.Web/sites --query '[0].name' -o tsv
az webapp deploy --resource-group $resourceGroup --name $apiName --src-path .\artifacts\api.zip --type zip
```

Acquire a token from an approved Entra client application that has consent for `api://<API_APP_CLIENT_ID>/user_impersonation`:

```powershell
$apiClientId = '<API_APP_CLIENT_ID>'
$token = az account get-access-token --scope "api://$apiClientId/user_impersonation" --query accessToken -o tsv
$apiUrl = $outputs.apiUrl.value
Invoke-RestMethod -Method Get -Uri "$apiUrl/healthz"
```

`GET /healthz` is private-network scoped and intentionally unauthenticated. All job endpoints require the delegated scope and each job/artifact lookup is bound to the caller's Entra `oid`.

## Test and report

Generate identical fixtures in Blob and Azure Files (10 MiB, 500 MiB, 2 GiB). The script fills files with deterministic bytes; it can require a long upload and incurs storage/transaction/network costs.

```powershell
.\scripts\Prepare-TestData.ps1 -ResourceGroup $resourceGroup -BlobStorageAccount $outputs.blobStorageAccountName.value -FileStorageAccount $outputs.fileStorageAccountName.value -OutputManifest .\artifacts\test-data-manifest.json
.\scripts\Invoke-LoadTest.ps1 -ApiBaseUrl $apiUrl -AccessToken $token -ExecutableBlob apps/CopyProbe.exe -ExecutableVersion v1 -ManifestPath .\artifacts\test-data-manifest.json -Arguments @('{input:0}') -OutputCsv .\artifacts\jobs.csv
.\scripts\New-ComparisonReport.ps1 -ManifestCsv .\artifacts\jobs.csv -SqlServerFqdn $outputs.sqlServerFqdn.value -Database $outputs.sqlDatabaseName.value -OutputDirectory .\artifacts\report
```

The harness executes paired mode runs serially per scenario to avoid the two modes competing with each other; the order is reversed for the medium scenario to reduce systematic ordering bias. S1/S2 submit 50 jobs each; S3 submits 20. The report contains mean API-to-start delay, p95 API-created-to-completed time, SMB mount failure rate (N/A for Blob), mount-attempt failure rate, Blob endpoint readiness failure rate, mean retries/job, files/sec, and jobs/hour. The raw SQL tables preserve per-job/per-file timestamps, attempt outcomes, byte counts, hashes, and error codes.

### API examples

```powershell
$headers = @{ Authorization = "Bearer $token" }
$body = @{
  executableBlob = 'apps/CopyProbe.exe'
  executableVersion = 'v1'
  copyMode = 'blob' # or 'azureFiles'
  inputs = @(@{ blobName = 'S1-10MB/input.bin'; expectedBytes = 10485760; expectedSha256 = '<64_HEX_SHA256>' })
  arguments = @('{input:0}')
  timeoutSeconds = 3600
} | ConvertTo-Json -Depth 6
$job = Invoke-RestMethod -Method Post -Uri "$apiUrl/jobs" -Headers $headers -ContentType 'application/json' -Body $body
Invoke-RestMethod -Method Get -Uri "$apiUrl/jobs/$($job.id)" -Headers $headers
Invoke-RestMethod -Method Get -Uri "$apiUrl/jobs/$($job.id)/artifacts" -Headers $headers
Invoke-RestMethod -Method Post -Uri "$apiUrl/jobs/$($job.id)/cancel" -Headers $headers
```

Arguments are a JSON array, not a command string. `{input:0}`, `{input:1}`, etc. are replaced by the corresponding node-local input path; other arguments are passed with Windows command-line quoting and no shell expansion.

## Deliberate limitations and Azure-side validation still required

- Azure Files identity-based SMB (AD DS/Entra Kerberos) is not provisioned: it requires an existing directory/domain-join design and file ACL policy. The PoC uses a dedicated account key from Key Vault as the practical Windows SMB authentication path. Move to identity-based SMB for production after domain integration.
- SQL external users and table-level grants are bootstrapped by `Initialize-Sql.ps1` after deployment because Bicep cannot create the application database principals without SQL admin credentials.
- Azure Batch's private endpoint group ID, regional Batch Private Link availability, disabled-public-access behavior, private DNS, pool no-public-IP networking, image/node-agent compatibility, quota/capacity, Azure Files SMB reachability, and task UAMI token availability must be validated in the target subscription/region. No Azure subscription deployment was run as part of this repository change.
- Private app deployment, SQL setup, Key Vault secret creation, and tests require a VNet-connected administration host. Publicly hosted CLI sessions cannot reach the deployed private data-plane endpoints.
- The load test compares application-level staging and execution time, not a pure NIC/SMB microbenchmark. VM SKU, node count/cold start, storage tier, region, file cache state, and run ordering influence results; preserve the manifest and raw metrics when comparing iterations.
- Cancellation is represented as terminal `failed` with `error_code='CANCELLED'` because the requested status list has no `cancelled` value. `mount_failed` and `upload_failed` are explicit terminal states.
- The sample EXE is a file-reading benchmark, not a production workload. Set expected EXE runtime, arguments, output patterns, file sizes, VM SKU, quota, and region for the real application before using the pool.
