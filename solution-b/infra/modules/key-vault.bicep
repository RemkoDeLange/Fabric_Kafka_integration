// Key Vault for storing mTLS certificates (CA, server, client)
// Uses RBAC authorization model (no access policies)

@description('Azure region')
param location string

@description('Resource name prefix')
param namePrefix string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${namePrefix}-kv'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    publicNetworkAccess: 'Enabled' // Required for deployment scripts to upload certs
  }
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
