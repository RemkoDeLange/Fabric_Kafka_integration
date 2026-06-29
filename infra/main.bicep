// Main orchestrator: deploys all modules for the Kafka dev environment
// Usage: az deployment group create -g rg-kafka-dev-01 -f infra/main.bicep -p infra/main.bicepparam

targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = 'westeurope'

@description('Base name prefix for all resources (keep short, lowercase, no special chars)')
@minLength(6)
@maxLength(15)
param namePrefix string = 'kafkadev01'

@description('Your public IP for SSH access (CIDR, e.g. 1.2.3.4/32). Find at https://ifconfig.me')
param allowedSshSourceIp string

@description('SSH public key for the Kafka VM')
@secure()
param adminSshPublicKey string

// --- Network ---
module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    namePrefix: namePrefix
    allowedSshSourceIp: allowedSshSourceIp
  }
}

// --- Event Hub ---
module eventHub 'modules/event-hub.bicep' = {
  name: 'eventHub'
  params: {
    location: location
    namePrefix: namePrefix
  }
}

// --- Private Endpoint (Event Hub → VNet) ---
module privateEndpoint 'modules/private-endpoint.bicep' = {
  name: 'privateEndpoint'
  params: {
    location: location
    namePrefix: namePrefix
    eventHubNamespaceId: eventHub.outputs.namespaceId
    privateEndpointsSubnetId: network.outputs.privateEndpointsSubnetId
    vnetId: network.outputs.vnetId
  }
}

// --- Kafka VM ---
module kafkaVm 'modules/vm-kafka.bicep' = {
  name: 'kafkaVm'
  params: {
    location: location
    namePrefix: namePrefix
    subnetId: network.outputs.defaultSubnetId
    adminSshPublicKey: adminSshPublicKey
  }
}

// --- Outputs ---
output kafkaVmPublicIp string = kafkaVm.outputs.vmPublicIp
output kafkaVmPrivateIp string = kafkaVm.outputs.vmPrivateIp
output kafkaVmSshCommand string = 'ssh ${kafkaVm.outputs.adminUsername}@${kafkaVm.outputs.vmPublicIp}'
output eventHubNamespaceName string = eventHub.outputs.namespaceName
output eventHubName string = eventHub.outputs.eventHubName
output eventHubKafkaEndpoint string = eventHub.outputs.kafkaEndpoint
output getConnectionStringCommand string = eventHub.outputs.connectionStringNote
output aciSubnetId string = network.outputs.aciSubnetId
