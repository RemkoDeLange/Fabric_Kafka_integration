# Fabric Real-Time Intelligence Setup

Manual steps to configure Fabric Eventstream and KQL Database.
These cannot be automated via Bicep — they are configured in the Fabric portal.

## Prerequisites

- Fabric workspace with F SKU capacity (or Trial) in **West Europe**
- **Workspace Identity** enabled (Settings → Identity) — required for Entra ID auth to Event Hub
- Workspace Admin role (needed for Managed Private Endpoints)
- Event Hub namespace deployed and private endpoint active

---

## Step 1: Create Eventhouse + KQL Database

1. Go to your Fabric workspace
2. Click **+ New** → **Eventhouse**
3. Name: `events-eventhouse`
4. This automatically creates a KQL Database with the same name

### Create the Events table

In the KQL Database, open a query window and run:

```kql
.create table Events (
    Timestamp: datetime,
    DeviceId: string,
    Temperature: real,
    Humidity: real,
    Location: string
)
```

Set an ingestion mapping for JSON:

```kql
.create table Events ingestion json mapping 'EventsMapping'
    '[{"column":"Timestamp","path":"$.timestamp","datatype":"datetime"},'
    '{"column":"DeviceId","path":"$.device_id","datatype":"string"},'
    '{"column":"Temperature","path":"$.temperature","datatype":"real"},'
    '{"column":"Humidity","path":"$.humidity","datatype":"real"},'
    '{"column":"Location","path":"$.location","datatype":"string"}]'
```

---

## Step 2: Create Managed Private Endpoint (Fabric → Event Hub)

1. In your Fabric workspace → **Settings** (gear icon) → **Network security**
2. Under **Managed private endpoints**, click **+ New**
3. Fill in:
   - **Name**: `pe-eventhub-kafkadev01a`
   - **Resource ID**: `/subscriptions/<sub-id>/resourceGroups/rg-kafka-bridge-01/providers/Microsoft.EventHub/namespaces/kafkadev01a-ehns`
   - **Target sub-resource**: `namespace`
4. Click **Create**

### Approve in Azure Portal

5. Go to Azure Portal → Event Hub namespace `kafkadev01a-ehns`
6. **Networking** → **Private endpoint connections** tab
7. Find the pending connection from Fabric → click **Approve**

> Allow a few minutes for the endpoint to become active.

---

## Step 3: Create Eventstream

1. In your Fabric workspace → **+ New** → **Eventstream**
2. Name: `eh-to-kql-stream`
3. Click **Add source** → **Azure Event Hubs**
4. Configure:
   - **Connection**: Create new
   - **Event Hub namespace**: `kafkadev01a-ehns.servicebus.windows.net`
   - **Event Hub**: `events-ingest`
   - **Shared Access Key Name**: `fabric-listen`
   - **Shared Access Key**: *(from authorization rule — see below)*
   - **Consumer group**: `$Default`
   - **Authentication**: **Shared Access Key**
   - **Data format**: JSON
   - **Skip test connection**: ✅ *(public access is disabled; MPE handles connectivity)*
5. Click **Add**

> **Known Limitation (as of July 2026)**: The Eventstream Azure Event Hub source connector
> supports **only** Shared Access Key authentication. Workspace Identity / Entra ID is not
> available in the connector dropdown, even when network connectivity is via Managed Private
> Endpoint. This requires `disableLocalAuth=false` on the namespace and a SAS authorization rule.

> **Environment Note**: If your Azure subscription enforces `disableLocalAuth=true` via
> Defender for Cloud or Azure Policy (common in enterprise/lab environments), SAS authentication
> will be blocked and this connector cannot function. In that case, consider Solution B
> (vNet Data Gateway + native Kafka protocol with mTLS), which avoids SAS entirely.

### Create the SAS Authorization Rule

```bash
# Create a Listen-only policy on the event hub
az eventhubs eventhub authorization-rule create \
  --name fabric-listen \
  --namespace-name kafkadev01a-ehns \
  --resource-group rg-kafka-bridge-01 \
  --eventhub-name events-ingest \
  --rights Listen

# Retrieve the key
az eventhubs eventhub authorization-rule keys list \
  --name fabric-listen \
  --namespace-name kafkadev01a-ehns \
  --resource-group rg-kafka-bridge-01 \
  --eventhub-name events-ingest \
  --query primaryKey -o tsv
```

> **Security note**: The VM→Event Hub path remains fully passwordless (OAuth/Managed Identity).
> Only the Fabric Eventstream ingestion leg requires this SAS key, scoped to Listen-only on a
> single event hub. The key is stored in Fabric's encrypted cloud connection store.

### Add Destination

6. Click **Add destination** → **Eventhouse** (or KQL Database)
7. Configure:
   - **Workspace**: your workspace
   - **Eventhouse**: `events-eventhouse`
   - **Database**: `events-eventhouse`
   - **Table**: `Events`
   - **Input data format**: JSON
   - **Ingestion mapping**: `EventsMapping`
   - **Ingestion mode**: Direct ingestion (lower latency)
8. Click **Add**
9. Click **Publish** to activate the eventstream

---

## Step 4: Validate

Once events are flowing (event generator → Kafka → Event Hub → Fabric), run these KQL queries:

### Check data is arriving
```kql
Events
| count
```

### View latest events
```kql
Events
| top 10 by Timestamp desc
```

### Check event rate
```kql
Events
| summarize count() by bin(Timestamp, 1m)
| render timechart
```

### Check end-to-end latency
```kql
Events
| extend Latency = ingestion_time() - Timestamp
| summarize avg(Latency), max(Latency), percentile(Latency, 95) by bin(Timestamp, 1m)
```

---

## Future: Eventstream Apache Kafka Connector (Phase 5)

When the Eventstream Kafka source connector supports private VNet connectivity:

1. In Eventstream → **Add source** → **Apache Kafka**
2. Configure:
   - Bootstrap servers: `<kafka-vm-private-ip>:9092`
   - Security protocol: PLAINTEXT (or SASL_SSL if TLS configured)
   - Topic: `iot-events`
   - Consumer group: `fabric-direct`
3. For private connectivity: set up a **Streaming VNet Data Gateway** in your VNet
4. Destination: same `Events` table (or a parallel `EventsDirect` table for comparison)

This bypasses Event Hub entirely: Kafka → Fabric directly.
