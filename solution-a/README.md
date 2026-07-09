# Solution A — Event Hub Bridge (OAuth / Managed Identity)

Private Kafka cluster → OAuth bridge (Managed Identity) → Azure Event Hub → Fabric Eventstream → KQL DB

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Azure VNet (10.0.0.0/16)                                     │
│                                                              │
│  ┌──────────────────────────┐   ┌─────────────────────────┐ │
│  │ kafka-subnet (10.0.1.0/24)│   │ pe-subnet (10.0.3.0/24) │ │
│  │                          │   │                         │ │
│  │  ┌────────────────────┐  │   │  ┌───────────────────┐ │ │
│  │  │ Kafka VM           │  │   │  │ Private Endpoint   │ │ │
│  │  │ :9092 PLAINTEXT    │  │   │  │ (Event Hub NS)     │ │ │
│  │  │                    │  │   │  └─────────┬─────────┘ │ │
│  │  │ Kafka (KRaft)      │  │   │            │           │ │
│  │  │ Kafka Connect      │  │   └────────────┼───────────┘ │
│  │  │ Event Generator    │  │                │             │
│  │  │ OAuth Bridge       │──┼────────────────┘             │
│  │  └────────────────────┘  │                              │
│  └──────────────────────────┘                              │
└──────────────────────────────────────────────────────────────┘
          │ SASL_SSL + OAUTHBEARER (Managed Identity token)
          ▼
┌──────────────────────────────────────┐
│ Event Hub Namespace (Standard)       │
│ kafkadev01a-ehns                     │
│ ├── iot-events (4 partitions)        │
│ └── Kafka protocol enabled           │
│                                      │
│ Auth: Entra ID (VM→EH) + SAS key  │
│       (Eventstream connector)        │
└──────────────────────┬───────────────┘
                       │
                       ▼
┌──────────────────────────────────────┐
│ Fabric Eventstream                   │
│ (Event Hub source)                   │
│         │                            │
│         ▼                            │
│ KQL Database (Eventhouse)            │
└──────────────────────────────────────┘
```

## Security

- **VM → Event Hub**: SASL_SSL with OAUTHBEARER (Managed Identity)
- **Eventstream → Event Hub**: Shared Access Key (Listen-only SAS policy — connector limitation)
- **Network**: Managed Private Endpoint for Event Hub; no public access
- **Identity**: System-assigned Managed Identity with "Event Hubs Data Sender" RBAC role (VM side)
- **Local auth**: Enabled (required for Eventstream SAS connector); scoped to Listen-only
- **Near-zero secrets**: Only a single SAS key stored in Fabric cloud connection; VM side is fully passwordless

## Components

| Component | Purpose |
|-----------|---------|
| `infra/main.bicep` | VNet, Event Hub (private endpoint), VM, RBAC role assignment |
| `kafka/setup-kafka.sh` | Deploys Kafka (KRaft mode) + Kafka Connect via Docker Compose |
| `kafka/kafka-connect/eventhub-sink.json` | MirrorSourceConnector config: local Kafka → Event Hub (SASL_PLAIN) |
| `event-generator/generator.py` | Simulated IoT telemetry producer (10 events/sec) |
| `fabric/README.md` | Fabric Eventstream + Eventhouse setup guide |

## Prerequisites

- Azure CLI ≥ 2.60
- Azure subscription with Contributor access
- Fabric capacity (F SKU or Trial) in West Europe
- SSH key pair (ed25519)

## Deployment

### 1. Deploy Infrastructure

```bash
# Create resource group
az group create --name rg-kafka-bridge-01 --location westeurope

# Deploy (creates VNet, Event Hub with PE, VM with Managed Identity, RBAC)
az deployment group create \
  --resource-group rg-kafka-bridge-01 \
  --template-file infra/main.bicep \
  --parameters adminSshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

### 2. Setup Kafka on VM

```bash
VM_NAME=$(az deployment group show -g <rg> -n main \
  --query properties.outputs.kafkaVmName.value -o tsv)

# Setup Kafka (Docker, KRaft mode) + Kafka Connect
az vm run-command invoke \
  --resource-group <rg> \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts @kafka/setup-kafka.sh
```

### 3. Create Event Hub Entity + Deploy Connector

```bash
# Create the iot-events entity on Event Hub
EHNS=$(az deployment group show -g <rg> -n main \
  --query properties.outputs.eventHubNamespaceName.value -o tsv)

az eventhubs eventhub create \
  --resource-group <rg> \
  --namespace-name "$EHNS" \
  --name iot-events \
  --partition-count 4 \
  --cleanup-policy Delete \
  --retention-time-in-hours 24

# Get connection string
CONN_STR=$(az eventhubs namespace authorization-rule keys list \
  --resource-group <rg> \
  --namespace-name "$EHNS" \
  --name KafkaConnectPolicy \
  --query primaryConnectionString -o tsv)

# Deploy connector (see kafka/kafka-connect/README.md for details)
# Edit eventhub-sink.json with your namespace and connection string, then:
az vm run-command invoke \
  --resource-group <rg> \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "curl -X POST http://localhost:8083/connectors -H 'Content-Type: application/json' -d @/path/to/eventhub-sink.json"
```

### 4. Start Event Generator

```bash
az vm run-command invoke \
  --resource-group <rg> \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts @event-generator/start-generator.sh
```

### 5. Configure Fabric

Follow the steps in [fabric/README.md](fabric/README.md) to:
1. Create Eventhouse + KQL Database
2. Create Managed Private Endpoint (Fabric → Event Hub) and approve it
3. Create Eventstream with Event Hub source (SAS key auth via MPE)
4. Route data to KQL table (direct ingestion)

## Verify

```bash
# Check connector is delivering
az vm run-command invoke -g <rg> -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "docker logs kafka-connect --tail 10 2>&1 | grep 'Committing offsets'"

# Check Event Hub metrics (should show ~600 msgs/min)
az monitor metrics list \
  --resource "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.EventHub/namespaces/$EHNS" \
  --metric "IncomingMessages" --interval PT1M \
  --query "value[0].timeseries[0].data[-3:]" -o table
```

## Cleanup

```bash
az group delete --name <rg> --yes --no-wait
```
