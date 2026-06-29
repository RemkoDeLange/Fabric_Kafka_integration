// Private Endpoint module: PE + Private DNS Zone + VNet Link + DNS Zone Group
// Connects Event Hub namespace to the VNet via private IP

@description('Azure region')
param location string

@description('Base name prefix for resources')
param namePrefix string

@description('Resource ID of the Event Hub namespace')
param eventHubNamespaceId string

@description('Resource ID of the private-endpoints subnet')
param privateEndpointsSubnetId string

@description('Resource ID of the VNet (for DNS zone link)')
param vnetId string

// --- Private DNS Zone ---
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.servicebus.windows.net'
  location: 'global'
}

// --- Link DNS Zone to VNet ---
resource dnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${namePrefix}-vnet-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

// --- Private Endpoint ---
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: '${namePrefix}-pe-eventhub'
  location: location
  properties: {
    subnet: {
      id: privateEndpointsSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${namePrefix}-plsc-eventhub'
        properties: {
          privateLinkServiceId: eventHubNamespaceId
          groupIds: [
            'namespace'
          ]
        }
      }
    ]
  }
}

// --- DNS Zone Group (auto-creates A record in DNS zone) ---
resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-servicebus-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

// --- Outputs ---
output privateEndpointId string = privateEndpoint.id
output privateDnsZoneId string = privateDnsZone.id
