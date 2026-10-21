targetScope = 'resourceGroup'

@minLength(3)
@maxLength(10)
@description('리소스 이름 접두사입니다. 영문 소문자와 숫자만 사용할 수 있습니다.')
param namePrefix string = 'hpcbatch'

@description('배포할 Azure 리전입니다. 기본값은 Korea Central(koreacentral)입니다.')
param location string = 'koreacentral'
param sqlAdminLogin string
param sqlAdminObjectId string
@description('API JWT 토큰 검증에 사용할 기존 Entra 앱 등록의 대상 URI 또는 앱 ID입니다.')
param apiAudience string
@description('Windows Azure Batch 컴퓨팅 SKU입니다. 배포 전에 해당 리전의 할당량과 용량을 확인하세요.')
param batchVmSize string = 'Standard_D4as_v5'
@minValue(1)
@maxValue(50)
param batchMaxNodes int = 50

var suffix = uniqueString(subscription().id, resourceGroup().id)
var keyVaultSuffix = substring(suffix, 0, 8)
var blobAccountName = 'b${suffix}'
var filesAccountName = 'f${suffix}'
var batchAccountName = 'ba${suffix}'
var vaultName = 'kv-${namePrefix}-${keyVaultSuffix}'
var sqlServerName = 'sql-${namePrefix}-${suffix}'
var appName = 'api-${namePrefix}-${suffix}'
var poolName = 'windows-poc'
var blobDelegatorRole = 'db58b8e5-c6ad-4a2a-8342-4190687cbf4a'
var blobReaderRole = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var blobContributorRole = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var keyVaultSecretsUserRole = '4633458b-17de-408a-b874-0445c86b69e6'
var batchContributorRole = '29fe4964-1e60-436b-bd3a-77fd4c178b3c'
var privateDnsNames = [
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.file.${environment().suffixes.storage}'
  'privatelink.${environment().suffixes.sqlServerHostname}'
  'privatelink.vaultcore.${replace(environment().suffixes.keyvaultDns, 'vault.', '')}'
  'privatelink.batch.azure.com'
  'privatelink.azurewebsites.net'
]

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.40.0.0/16' ] }
    subnets: [
      {
        name: 'batch'
        properties: {
          addressPrefix: '10.40.2.0/23'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: '10.40.4.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'app-integration'
        properties: {
          addressPrefix: '10.40.1.0/24'
          delegations: [
            {
              name: 'web-app-delegation'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
            }
          ]
        }
      }
    ]
  }
}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zoneName in privateDnsNames: {
  name: zoneName
  location: 'global'
}]

resource privateDnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zoneName, index) in privateDnsNames: {
  parent: privateDnsZones[index]
  name: '${namePrefix}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'private-endpoints'
}

resource batchSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'batch'
}

resource apiSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'app-integration'
}

resource apiIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-api-mi'
  location: location
}

resource workerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-worker-mi'
  location: location
}

resource blobStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: blobAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Deny', ipRules: [], virtualNetworkRules: [] }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: blobStorage
  name: 'default'
}

resource inputContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'inputs'
  properties: { publicAccess: 'None' }
}

resource outputContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'outputs'
  properties: { publicAccess: 'None' }
}

resource bootstrapContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'bootstrap'
  properties: { publicAccess: 'None' }
}

resource payloadContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'jobpayloads'
  properties: { publicAccess: 'None' }
}

resource filesStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: filesAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Deny', ipRules: [], virtualNetworkRules: [] }
    largeFileSharesState: 'Enabled'
  }
}

resource filesService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: filesStorage
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: filesService
  name: 'inputs'
  properties: { shareQuota: 1024, enabledProtocols: 'SMB' }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { bypass: 'None', defaultAction: 'Deny', ipRules: [], virtualNetworkRules: [] }
  }
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'Group'
      login: sqlAdminLogin
      sid: sqlAdminObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: 'batchpoc'
  location: location
  sku: { name: 'GP_S_Gen5_1', tier: 'GeneralPurpose', family: 'Gen5', capacity: 1 }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 34359738368
    autoPauseDelay: 60
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: 'Local'
  }
}

resource batchAccount 'Microsoft.Batch/batchAccounts@2025-06-01' = {
  name: batchAccountName
  location: location
  properties: {
    poolAllocationMode: 'BatchService'
    publicNetworkAccess: 'Disabled'
    allowedAuthenticationModes: [ 'AAD' ]
  }
}

resource batchPool 'Microsoft.Batch/batchAccounts/pools@2025-06-01' = {
  parent: batchAccount
  name: poolName
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${workerIdentity.id}': {} }
  }
  properties: {
    displayName: 'Windows 파일 입출력 PoC'
    vmSize: batchVmSize
    taskSlotsPerNode: 1
    deploymentConfiguration: {
      virtualMachineConfiguration: {
        imageReference: {
          publisher: 'MicrosoftWindowsServer'
          offer: 'WindowsServer'
          sku: '2022-datacenter'
          version: 'latest'
        }
        nodeAgentSkuId: 'batch.node.windows amd64'
        windowsConfiguration: { enableAutomaticUpdates: false }
      }
    }
    scaleSettings: {
      autoScale: {
        evaluationInterval: 'PT1M'
        formula: '$TargetDedicatedNodes = min(${batchMaxNodes}, max(0, $PendingTasks.GetSample(1)));'
      }
    }
    networkConfiguration: {
      subnetId: batchSubnet.id
      publicIPAddressConfiguration: { provision: 'NoPublicIPAddresses' }
    }
  }
}

resource servicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${namePrefix}-api-plan'
  location: location
  kind: 'windows'
  sku: { name: 'P1v3', tier: 'PremiumV3', capacity: 1 }
  properties: { reserved: false, zoneRedundant: false }
}

resource api 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  kind: 'app'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${apiIdentity.id}': {} }
  }
  properties: {
    serverFarmId: servicePlan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: apiSubnet.id
    vnetRouteAllEnabled: true
    siteConfig: {
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      windowsFxVersion: 'DOTNETCORE|8.0'
      appSettings: [
        { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
        { name: 'Azure__SqlConnectionString', value: 'Server=tcp:${sqlServer.name}.${environment().suffixes.sqlServerHostname},1433;Database=${sqlDatabase.name};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;' }
        { name: 'Azure__BatchEndpoint', value: 'https://${batchAccount.name}.${location}.batch.azure.com' }
        { name: 'Azure__BatchPoolId', value: poolName }
        { name: 'Azure__StorageAccountUrl', value: 'https://${blobStorage.name}.blob.${environment().suffixes.storage}' }
        { name: 'Azure__PayloadContainer', value: payloadContainer.name }
        { name: 'Azure__FileShareAccountName', value: filesStorage.name }
        { name: 'Azure__FileShareName', value: fileShare.name }
        { name: 'Azure__KeyVaultUrl', value: 'https://${vault.name}.${environment().suffixes.keyvaultDns}' }
        { name: 'Azure__ApiManagedIdentityClientId', value: apiIdentity.properties.clientId }
        { name: 'Azure__WorkerManagedIdentityClientId', value: workerIdentity.properties.clientId }
        { name: 'Authentication__TenantId', value: tenant().tenantId }
        { name: 'Authentication__Audience', value: apiAudience }
        { name: 'Azure__MonitorIntervalSeconds', value: '15' }
        { name: 'Azure__ArtifactSasMinutes', value: '30' }
        { name: 'Azure__BootstrapSasMinutes', value: '240' }
      ]
    }
  }
}

resource apiStartup 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: api
  name: 'web'
  properties: {
    netFrameworkVersion: 'v8.0'
    alwaysOn: true
    ftpsState: 'Disabled'
    minTlsVersion: '1.2'
    http20Enabled: true
    ipSecurityRestrictionsDefaultAction: 'Deny'
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${namePrefix}-blob-pe'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: blobStorage.id
          groupIds: [ 'blob' ]
        }
      }
    ]
  }
}

resource filePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${namePrefix}-file-pe'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'file'
        properties: {
          privateLinkServiceId: filesStorage.id
          groupIds: [ 'file' ]
        }
      }
    ]
  }
}

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${namePrefix}-sql-pe'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'sql'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [ 'sqlServer' ]
        }
      }
    ]
  }
}

resource vaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${namePrefix}-vault-pe'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: [ 'vault' ]
        }
      }
    ]
  }
}

resource batchPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${namePrefix}-batch-pe'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'batch'
        properties: {
          privateLinkServiceId: batchAccount.id
          groupIds: [ 'batchAccount' ]
        }
      }
    ]
  }
}

resource apiPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${namePrefix}-api-pe'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'api'
        properties: {
          privateLinkServiceId: api.id
          groupIds: [ 'sites' ]
        }
      }
    ]
  }
}

resource blobPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: { privateDnsZoneId: privateDnsZones[0].id }
      }
    ]
  }
}

resource filePeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: filePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'file'
        properties: { privateDnsZoneId: privateDnsZones[1].id }
      }
    ]
  }
}

resource sqlPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: sqlPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: { privateDnsZoneId: privateDnsZones[2].id }
      }
    ]
  }
}

resource vaultPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: vaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: { privateDnsZoneId: privateDnsZones[3].id }
      }
    ]
  }
}

resource batchPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: batchPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'batch'
        properties: { privateDnsZoneId: privateDnsZones[4].id }
      }
    ]
  }
}

resource apiPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: apiPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'api'
        properties: { privateDnsZoneId: privateDnsZones[5].id }
      }
    ]
  }
}

resource apiBatchRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(batchAccount.id, apiIdentity.id, batchContributorRole)
  scope: batchAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', batchContributorRole)
    principalId: apiIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apiBlobDelegatorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(blobStorage.id, apiIdentity.id, blobDelegatorRole)
  scope: blobStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDelegatorRole)
    principalId: apiIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apiBootstrapReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bootstrapContainer.id, apiIdentity.id, blobReaderRole)
  scope: bootstrapContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobReaderRole)
    principalId: apiIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apiOutputReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(outputContainer.id, apiIdentity.id, blobReaderRole)
  scope: outputContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobReaderRole)
    principalId: apiIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apiPayloadWriterRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(payloadContainer.id, apiIdentity.id, blobContributorRole)
  scope: payloadContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobContributorRole)
    principalId: apiIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource workerInputReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(inputContainer.id, workerIdentity.id, blobReaderRole)
  scope: inputContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobReaderRole)
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource workerPayloadReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(payloadContainer.id, workerIdentity.id, blobReaderRole)
  scope: payloadContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobReaderRole)
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource workerOutputWriterRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(outputContainer.id, workerIdentity.id, blobContributorRole)
  scope: outputContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobContributorRole)
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource workerKeyVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, workerIdentity.id, keyVaultSecretsUserRole)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRole)
    principalId: workerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output batchAccountName string = batchAccount.name
output batchPoolName string = batchPool.name
output batchEndpoint string = 'https://${batchAccount.name}.${location}.batch.azure.com'
output apiUrl string = 'https://${api.name}.azurewebsites.net'
output apiPrivateEndpointId string = apiPrivateEndpoint.id
output apiIdentityName string = apiIdentity.name
output apiIdentityClientId string = apiIdentity.properties.clientId
output apiIdentityPrincipalId string = apiIdentity.properties.principalId
output workerIdentityName string = workerIdentity.name
output workerIdentityClientId string = workerIdentity.properties.clientId
output workerIdentityPrincipalId string = workerIdentity.properties.principalId
output blobStorageAccountName string = blobStorage.name
output storageAccountUrl string = 'https://${blobStorage.name}.blob.${environment().suffixes.storage}'
output fileStorageAccountName string = filesStorage.name
output fileShareName string = fileShare.name
output keyVaultName string = vault.name
output keyVaultUrl string = 'https://${vault.name}.${environment().suffixes.keyvaultDns}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDatabase.name
output privateDnsZoneNames array = privateDnsNames
