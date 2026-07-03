# Solution B — Fabric Configuration (Direct Kafka Ingestion via mTLS)

## Overview

Fabric Eventstream connects **directly** to the private Kafka cluster using the Apache Kafka source connector (GA July 2026) with mTLS authentication over a Streaming vNet Data Gateway.

## Prerequisites

- Fabric workspace with a **Workspace Identity** (Settings → Identity)
- The workspace identity needs **Network Contributor** role on the VNet
- `Microsoft.MessagingConnectors` resource provider registered on the subscription
- Feature flag `Microsoft.MessagingConnectors/DefaultFeature` must be **Registered** (not Pending)
- Certificates uploaded to Key Vault in PEM format (done by Bicep deployment)
- Key Vault accessible from the delegated subnet (same VNet)

## Step 1: Register Resource Provider & Feature Flag

```bash
# Register the resource provider
az provider register --namespace Microsoft.MessagingConnectors
az provider show --namespace Microsoft.MessagingConnectors --query registrationState

# Register the feature flag (required for gateway creation)
az feature register --namespace Microsoft.MessagingConnectors --name DefaultFeature
az feature show --namespace Microsoft.MessagingConnectors --name DefaultFeature --query "properties.state" -o tsv

# After feature flag shows 'Registered', re-register provider to propagate
az provider register --namespace Microsoft.MessagingConnectors
```

> **Note**: The feature flag may take time to approve. Gateway creation is blocked until
> the state changes from `Pending` to `Registered`. See [Known Blockers](#known-blockers).

## Step 2: Assign Network Contributor to Workspace Identity

Get the workspace identity's Object ID from the Fabric portal (Workspace Settings → Identity), then:

```bash
WORKSPACE_IDENTITY_OID="<from-fabric-portal>"
VNET_ID=$(az network vnet show -g rg-kafka-direct-01 -n kafkadev01b-vnet --query id -o tsv)

az role assignment create \
  --assignee-object-id "$WORKSPACE_IDENTITY_OID" \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "$VNET_ID"
```

## Step 3: Create Streaming vNet Data Gateway

1. In Fabric portal → **Settings** (gear icon) → **Manage connections and gateways**
2. Click the **Virtual network data gateways** tab → **+ New**
3. Select gateway type: **Streaming** (required for Eventstream sources)
4. Configure:
   - Name: `kafka-mtls-gateway`
   - Subscription: `ME-MngEnvMCAP675185-redelang-1`
   - Resource Group: `rg-kafka-direct-01`
   - VNet: `kafkadev01b-vnet`
   - Subnet: `connector-delegated` (10.1.2.0/24)
   - Region: West Europe

## Step 4: Create Eventhouse + KQL Database

1. In Fabric workspace → **New** → **Eventhouse**
2. Name: `iot-eventhouse`
3. A KQL database `iot-eventhouse` is auto-created

## Step 5: Create KQL Table

In the KQL database query editor:

```kql
.create table IotEvents (
    timestamp: datetime,
    device_id: string,
    temperature: real,
    humidity: real,
    location: string
)
```

## Step 6: Create Eventstream with Apache Kafka Source

1. In Fabric workspace → **New** → **Eventstream**
2. Name: `kafka-mtls-stream`
3. Add source → **Apache Kafka**
4. Configure:
   - **Bootstrap server**: `10.1.1.4:9093`
   - **Topic**: `iot-events`
   - **Consumer group**: `fabric-eventstream`
   - **Connection**: Create new
     - Authentication: **Custom CA certificate + mTLS**
     - CA certificate: Upload or reference from Key Vault (`ca-cert`)
     - Client certificate: Reference from Key Vault (`client-cert`)
     - Client key: Reference from Key Vault (`client-key`)
   - **Gateway**: Select `kafka-mtls-gateway`
5. Add destination → **KQL Database**
   - Database: `iot-eventhouse`
   - Table: `IotEvents`
   - Input data format: JSON
   - Map fields appropriately

## Step 7: Verify Data Flow

In the KQL database:

```kql
IotEvents
| take 10
| order by timestamp desc
```

```kql
IotEvents
| where timestamp > ago(5m)
| summarize count() by bin(timestamp, 1m)
| render timechart
```

## Known Blockers

| Blocker | Status | Notes |
|---------|--------|-------|
| `Microsoft.MessagingConnectors/DefaultFeature` stuck at **Pending** | ⏳ Waiting | Raised with internal CAT team 2026-07-03. Gateway creation is impossible until this resolves. Subnet appears greyed out in Fabric portal. |

## Troubleshooting

| Issue | Resolution |
|-------|------------|
| Subnet greyed out in gateway wizard | Feature flag `DefaultFeature` not yet Registered — wait for approval |
| Eventstream can't connect | Verify gateway subnet has delegation to `Microsoft.MessagingConnectors/Connectors` |
| Certificate error | Ensure certs are PEM format in Key Vault with `contentType: application/x-pem-file` |
| No data flowing | Check Kafka topic has data: `kafka-topics.sh --describe --topic iot-events` |
| Gateway creation fails | Verify workspace identity has Network Contributor on VNet |

## References

- [Add Apache Kafka source to Eventstream](https://learn.microsoft.com/en-us/fabric/real-time-intelligence/event-streams/add-source-apache-kafka)
- [Streaming connector VNet support guide](https://learn.microsoft.com/en-us/fabric/real-time-intelligence/event-streams/streaming-connector-private-network-support-guide)
