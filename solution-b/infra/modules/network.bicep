// VNet for Solution B: Direct Kafka Ingestion
// Subnets: default (Kafka VM), connector-delegated (Fabric Streaming vNet Gateway)

@description('Azure region')
param location string

@description('Resource name prefix')
param namePrefix string

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: '${namePrefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.1.0.0/16']
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.1.1.0/24'
        }
      }
      {
        name: 'connector-delegated'
        properties: {
          addressPrefix: '10.1.2.0/24'
          delegations: [
            {
              name: 'messagingConnectors'
              properties: {
                serviceName: 'Microsoft.MessagingConnectors/Connectors'
              }
            }
          ]
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output defaultSubnetId string = vnet.properties.subnets[0].id
output connectorSubnetId string = vnet.properties.subnets[1].id
