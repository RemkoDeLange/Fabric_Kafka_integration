// Assigns Azure Event Hubs Data Sender role to the Kafka VM's managed identity
// This enables Kafka Connect to use SASL_OAUTHBEARER (OAuth 2.0) instead of connection strings

@description('Principal ID of the Kafka VM managed identity')
param principalId string

@description('Resource ID of the Event Hub namespace')
param eventHubNamespaceId string

// Azure Event Hubs Data Sender role definition ID
var eventHubsDataSenderRoleId = '2b629674-e913-4c01-ae53-ef4638d8f975'

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: last(split(eventHubNamespaceId, '/'))
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(eventHubNamespace.id, principalId, eventHubsDataSenderRoleId)
  scope: eventHubNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubsDataSenderRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
