// Assigns Key Vault Secrets User role to the Kafka VM managed identity
// Allows VM to download mTLS certificates at runtime

@description('Principal ID of the Kafka VM managed identity')
param principalId string

@description('Key Vault name')
param keyVaultName string

// Key Vault Secrets User role definition ID
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, principalId, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
