# Private Kafka → Event Hub → Fabric Real-Time Intelligence

End-to-end streaming pipeline: a private-network Kafka cluster forwards events via Kafka Connect to a private Azure Event Hub, which is ingested by Fabric Eventstream into a KQL Database.

## Architecture

```
ACI Event Generator → Kafka (VM, KRaft) → Kafka Connect → Event Hub (private) → Fabric Eventstream → KQL Database
```

All resources are deployed in a private Azure VNet (West Europe). Event Hub has no public access — connectivity is via Private Endpoint.

## Prerequisites

- Azure subscription with Contributor/Owner access
- Azure CLI installed (`az --version` ≥ 2.60)
- Fabric capacity (F SKU or Trial) in West Europe
- SSH key pair for VM access

## Quick Start

```bash
# 1. Login to Azure
az login
az account set --subscription "<your-subscription-id>"

# 2. Create resource group
az group create --name rg-kafka-dev-01 --location westeurope

# 3. Preview deployment (dry run)
az deployment group what-if \
  --resource-group rg-kafka-dev-01 \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam

# 4. Deploy infrastructure
az deployment group create \
  --resource-group rg-kafka-dev-01 \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam

# 5. Get outputs (VM IP, Event Hub connection string)
az deployment group show \
  --resource-group rg-kafka-dev-01 \
  --name main \
  --query properties.outputs
```

## Repo Structure

```
├── infra/                    # Bicep IaC
│   ├── main.bicep            # Orchestrator
│   ├── main.bicepparam.example  # Parameter template (copy and fill in)
│   └── modules/
│       ├── network.bicep
│       ├── event-hub.bicep
│       ├── private-endpoint.bicep
│       └── vm-kafka.bicep
├── kafka/                    # Kafka configuration
│   ├── docker-compose.yml
│   └── kafka-connect/
│       └── eventhub-sink.json
├── event-generator/          # Simulated event producer
│   ├── Dockerfile
│   ├── requirements.txt
│   └── generator.py
└── fabric/                   # Fabric setup instructions
    └── README.md
```

## Deployment Workflow

This is a dev environment — all deployments are manual CLI commands. No pipelines.

1. **Deploy infra** (Bicep) → creates VNet, Event Hub, Private Endpoint, Kafka VM
2. **SSH into VM** → start Kafka + Kafka Connect via Docker Compose
3. **Deploy event generator** (ACI) → produces events into Kafka
4. **Configure Fabric** (manual) → Eventstream + KQL Database

## Branches

- `main` — stable, deployed infrastructure
- `feature/infra` — infrastructure changes
- `feature/kafka-connect` — Kafka Connect configuration
- `feature/eventstream-kafka` — future Eventstream Kafka connector testing

## Cleanup

```bash
# Delete all Azure resources
az group delete --name rg-kafka-dev-01 --yes --no-wait
```
