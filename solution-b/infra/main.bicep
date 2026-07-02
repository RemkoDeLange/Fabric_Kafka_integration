// Main orchestrator: deploys all modules for Solution B (Direct Kafka Ingestion via mTLS)
// Usage: az deployment group create -g rg-kafka-direct-01 -f infra/main.bicep -p infra/main.bicepparam

targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = 'westeurope'

@description('Base name prefix for all resources')
@minLength(6)
@maxLength(15)
param namePrefix string = 'kafkadev01b'

@description('SSH public key for the Kafka VM')
@secure()
param adminSshPublicKey string

// --- Network ---
module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    namePrefix: namePrefix
  }
}

// --- Key Vault ---
module keyVault 'modules/key-vault.bicep' = {
  name: 'keyVault'
  params: {
    location: location
    namePrefix: namePrefix
  }
}

// --- Certificates ---
// Note: Certificate generation via deploymentScripts requires key-based storage auth.
// If blocked by policy, generate certs via CLI after deployment (see README).
// Uncomment if your subscription allows it:
// module certificates 'modules/certificates.bicep' = {
//   name: 'certificates'
//   params: {
//     location: location
//     keyVaultName: keyVault.outputs.keyVaultName
//     kafkaVmIp: '10.1.1.4'
//   }
// }

// --- Kafka VM (with mTLS) ---
module kafkaVm 'modules/vm-kafka.bicep' = {
  name: 'kafkaVm'
  params: {
    location: location
    namePrefix: namePrefix
    subnetId: network.outputs.defaultSubnetId
    adminSshPublicKey: adminSshPublicKey
    keyVaultName: keyVault.outputs.keyVaultName
  }
}

// --- RBAC: VM Managed Identity → Key Vault Secrets User ---
module kvRoleAssignment 'modules/kv-role-assignment.bicep' = {
  name: 'kvRoleAssignment'
  params: {
    principalId: kafkaVm.outputs.vmPrincipalId
    keyVaultName: keyVault.outputs.keyVaultName
  }
}

// --- Outputs ---
output kafkaVmPrivateIp string = kafkaVm.outputs.vmPrivateIp
output kafkaVmName string = kafkaVm.outputs.vmName
output keyVaultName string = keyVault.outputs.keyVaultName
output connectorSubnetId string = network.outputs.connectorSubnetId
