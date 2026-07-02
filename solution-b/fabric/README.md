# Solution B — Fabric Configuration (Direct Kafka Ingestion via mTLS)

## Overview

Fabric Eventstream connects **directly** to the private Kafka cluster using the Apache Kafka source connector (GA July 2026) with mTLS authentication over a Streaming vNet Data Gateway.

## Prerequisites

- Fabric workspace with a **Workspace Identity** (Settings → Identity)
- The workspace identity needs **Network Contributor** role on the VNet
- `Microsoft.PowerPlatform` resource provider registered on the subscription
- Certificates uploaded to Key Vault (done by Bicep deployment)

## Step 1: Register Resource Provider

```bash
az provider register --namespace Microsoft.PowerPlatform
az provider show --namespace Microsoft.PowerPlatform --query registrationState
```

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

1. In Fabric portal → **Manage connections and gateways**
2. Click **New** → **Virtual network data gateway**
3. Configure:
   - Name: `kafka-mtls-gateway`
   - VNet: `kafkadev01b-vnet`
   - Subnet: `connector-delegated` (10.1.2.0/27)
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

## Troubleshooting

| Issue | Resolution |
|-------|-----------|
| Eventstream can't connect | Verify gateway subnet has delegation to `Microsoft.PowerPlatform/vnetaccesslinks` |
| Certificate error | Ensure client cert is signed by same CA uploaded as trust anchor |
| No data flowing | Check Kafka topic has data: `kafka-topics.sh --describe --topic iot-events` |
| Gateway creation fails | Verify workspace identity has Network Contributor on VNet |
