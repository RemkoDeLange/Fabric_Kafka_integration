// Event Hub module: Namespace + Event Hub entity + auth rules
// Standard SKU with Kafka protocol, public access disabled

@description('Azure region')
param location string

@description('Base name prefix for resources')
@minLength(6)
param namePrefix string

// --- Event Hub Namespace ---
resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: '${namePrefix}-ehns'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    isAutoInflateEnabled: true
    maximumThroughputUnits: 4
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: '1.2'
    disableLocalAuth: false
  }
}

// --- Event Hub (Topic) ---
resource eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubNamespace
  name: 'events-ingest'
  properties: {
    partitionCount: 4
    messageRetentionInDays: 1
  }
}

// --- Shared Access Policy for Kafka Connect ---
resource kafkaConnectPolicy 'Microsoft.EventHub/namespaces/authorizationRules@2024-01-01' = {
  parent: eventHubNamespace
  name: 'KafkaConnectPolicy'
  properties: {
    rights: [
      'Send'
      'Listen'
    ]
  }
}

// --- Network rules: allow trusted Microsoft services (Fabric) ---
resource networkRules 'Microsoft.EventHub/namespaces/networkRuleSets@2024-01-01' = {
  parent: eventHubNamespace
  name: 'default'
  properties: {
    publicNetworkAccess: 'Disabled'
    defaultAction: 'Deny'
    trustedServiceAccessEnabled: true
    ipRules: []
    virtualNetworkRules: []
  }
}

// --- Outputs ---
output namespaceId string = eventHubNamespace.id
output namespaceName string = eventHubNamespace.name
output eventHubName string = eventHub.name
output kafkaConnectPolicyName string = kafkaConnectPolicy.name
output kafkaEndpoint string = '${eventHubNamespace.name}.servicebus.windows.net:9093'

@description('Connection string for Kafka Connect (retrieve after deployment via CLI)')
output connectionStringNote string = 'Run: az eventhubs namespace authorization-rule keys list --resource-group <rg> --namespace-name ${eventHubNamespace.name} --name KafkaConnectPolicy --query primaryConnectionString -o tsv'
