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
| `kafka/docker-compose.yml` | Kafka (KRaft mode) + Kafka Connect (unused — bridge used instead) |
| `kafka-bridge/bridge.py` | Python bridge: consumes local Kafka → produces to Event Hub via OAuth |
| `event-generator/generator.py` | Simulated IoT telemetry producer (10 events/sec) |
| `fabric/README.md` | Fabric Eventstream setup guide |

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
VM_NAME=$(az deployment group show -g rg-kafka-bridge-01 -n main \
  --query properties.outputs.kafkaVmName.value -o tsv)

# Setup Kafka (Docker, KRaft mode)
az vm run-command invoke \
  --resource-group rg-kafka-bridge-01 \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts @kafka/setup-kafka.sh
```

### 3. Start Event Generator

```bash
az vm run-command invoke \
  --resource-group rg-kafka-bridge-01 \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "cd /data/kafka/generator && setsid python3 -u generator.py > output.log 2>&1 < /dev/null &"
```

### 4. Start the OAuth Bridge

The bridge uses the VM's Managed Identity to authenticate to Event Hubs — no secrets needed.

```bash
az vm run-command invoke \
  --resource-group rg-kafka-bridge-01 \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "cd /data/kafka/bridge && setsid python3 -u bridge.py > bridge.log 2>&1 < /dev/null &"
```

### 5. Configure Fabric

Follow the steps in [fabric/README.md](fabric/README.md) to:
1. Create Eventhouse + KQL Database
2. Create Eventstream with Event Hub source (Entra ID auth)
3. Route data to KQL table

## How the OAuth Bridge Works

```python
# 1. Get token from Azure IMDS (Managed Identity)
token = requests.get(
    "http://169.254.169.254/metadata/identity/oauth2/token",
    params={"resource": "https://<namespace>.servicebus.windows.net"},
    headers={"Metadata": "true"}
)

# 2. Produce to Event Hub using Kafka protocol + OAUTHBEARER
producer = Producer({
    "bootstrap.servers": "<namespace>.servicebus.windows.net:9093",
    "security.protocol": "SASL_SSL",
    "sasl.mechanism": "OAUTHBEARER",
    "oauth_cb": lambda _: (token, expiry),
})
```

Key insight: the token audience must be `https://<namespace>.servicebus.windows.net` (namespace-specific), not the generic `https://eventhubs.azure.net`.

## Verify

```bash
# Check generator is producing
az vm run-command invoke -g rg-kafka-bridge-01 -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "tail -3 /data/kafka/generator/output.log"

# Check bridge is forwarding
az vm run-command invoke -g rg-kafka-bridge-01 -n "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "tail -3 /data/kafka/bridge/bridge.log"

# Check Event Hub metrics (should show ~600 msgs/min)
az monitor metrics list \
  --resource "/subscriptions/<sub-id>/resourceGroups/rg-kafka-bridge-01/providers/Microsoft.EventHub/namespaces/kafkadev01a-ehns" \
  --metric "IncomingMessages" --interval PT1M \
  --query "value[0].timeseries[0].data[-3:]"
```

## Cleanup

```bash
az group delete --name rg-kafka-bridge-01 --yes --no-wait
```
