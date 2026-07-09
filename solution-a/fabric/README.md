# Fabric Real-Time Intelligence Setup

Manual steps to configure Fabric Eventstream and Eventhouse (KQL Database).
These cannot be automated via Bicep — they are configured in the Fabric portal.

## Prerequisites

- Fabric workspace with F SKU capacity (or Trial) in **West Europe**
- Workspace Admin role (needed for Managed Private Endpoints)
- Event Hub namespace deployed and private endpoint active

---

## Step 1: Create Eventhouse + KQL Database

1. Go to your Fabric workspace
2. Click **+ New** → **Eventhouse**
3. Name: `iot-eventhouse`
4. This automatically creates a KQL Database with the same name

### Create the Events table

In the KQL Database, open a query window and run:

```kql
.create table IotEvents (
    timestamp: datetime,
    device_id: string,
    temperature: real,
    humidity: real,
    location: string
)
```

---

## Step 2: Create Managed Private Endpoint (Fabric → Event Hub)

Required because the Event Hub namespace has public network access disabled.

1. In your Fabric workspace → **Settings** (gear icon) → **Network security**
2. Under **Managed private endpoints**, click **+ New**
3. Fill in:
   - **Name**: `pe-fabric-eventhub-dev-01`
   - **Resource ID**: `/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.EventHub/namespaces/<namespace>`
   - **Target sub-resource**: `namespace`
4. Click **Create**

### Approve in Azure

```bash
# List pending connections
az network private-endpoint-connection list \
  --resource-group <rg> \
  --name <namespace> \
  --type Microsoft.EventHub/namespaces \
  --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].name" -o tsv

# Approve
az network private-endpoint-connection approve \
  --resource-group <rg> \
  --resource-name <namespace> \
  --type Microsoft.EventHub/namespaces \
  --name <connection-name> \
  --description "Approved for Fabric Eventstream"
```

> Allow a few minutes for the endpoint to become active.

---

## Step 3: Create Eventstream

1. In your Fabric workspace → **+ New** → **Eventstream**
2. Name: `es-kafka-eventhub-bridge`
3. Click **Add source** → **Azure Event Hubs**
4. Configure:
   - **Connection**: Create new
   - **Event Hub namespace**: `<namespace>.servicebus.windows.net`
   - **Event Hub**: `iot-events`
   - **Shared Access Key Name**: `EventstreamListenPolicy`
   - **Shared Access Key**: *(from namespace-level authorization rule — see below)*
   - **Consumer group**: `$Default`
   - **Authentication**: **Shared Access Key**
   - **Data format**: JSON
   - **Skip test connection**: ✅ *(public access is disabled; MPE handles connectivity)*
5. Click **Add**

### Create the Listen-only SAS Authorization Rule

```bash
# Create a namespace-level Listen-only policy
az eventhubs namespace authorization-rule create \
  --resource-group <rg> \
  --namespace-name <namespace> \
  --name EventstreamListenPolicy \
  --rights Listen

# Retrieve the key
az eventhubs namespace authorization-rule keys list \
  --resource-group <rg> \
  --namespace-name <namespace> \
  --name EventstreamListenPolicy \
  --query primaryKey -o tsv
```

### Add Destination

6. Click **Add destination** → **Eventhouse**
7. Configure:
   - **Workspace**: your workspace
   - **Eventhouse**: `iot-eventhouse`
   - **Database**: `iot-eventhouse`
   - **Table**: `IotEvents`
   - **Input data format**: JSON
   - **Ingestion mode**: Direct ingestion
8. Click **Finish**, then **Publish** to activate the eventstream

---

## Step 4: Validate

Once events are flowing (event generator → Kafka → Event Hub → Fabric), run these KQL queries:

### Check data is arriving
```kql
IotEvents
| count
```

### View latest events
```kql
IotEvents
| top 10 by timestamp desc
```

### Check event rate
```kql
IotEvents
| summarize count() by bin(timestamp, 1m)
| render timechart
```

### Check end-to-end latency
```kql
IotEvents
| extend Latency = ingestion_time() - timestamp
| summarize avg(Latency), max(Latency), percentile(Latency, 95) by bin(timestamp, 1m)
```
