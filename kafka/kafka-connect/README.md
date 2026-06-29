# Kafka Connect — Event Hub Sink Setup

## Overview

This uses Kafka's built-in MirrorSourceConnector to replicate events from the local Kafka topic
to Azure Event Hub (which speaks Kafka protocol natively on port 9093).

The connector replicates the `iot-events` topic to Event Hub's `iot-events` entity (same name).

## Prerequisites

1. Kafka + Kafka Connect running (via docker-compose)
2. Event Hub connection string from Azure:
   ```bash
   az eventhubs namespace authorization-rule keys list \
     --resource-group rg-kafka-dev-01 \
     --namespace-name kafkadev01-ehns \
     --name KafkaConnectPolicy \
     --query primaryConnectionString -o tsv
   ```

## Deploy the Connector

1. Edit `eventhub-sink.json`:
   - Replace `${EVENTHUB_NAMESPACE}` with your namespace name (e.g., `kafkadev01-ehns`)
   - Replace `${EVENTHUB_CONNECTION_STRING}` with the full connection string from above

2. Submit to Kafka Connect REST API:
   ```bash
   curl -X POST http://localhost:8083/connectors \
     -H "Content-Type: application/json" \
     -d @eventhub-sink.json
   ```

3. Check status:
   ```bash
   curl http://localhost:8083/connectors/eventhub-sink/status | jq
   ```

## Verify

- Check Event Hub metrics in Azure Portal → Event Hub → Metrics → Incoming Messages
- Or use Azure CLI:
  ```bash
  az monitor metrics list \
    --resource /subscriptions/<sub>/resourceGroups/rg-kafka-dev-01/providers/Microsoft.EventHub/namespaces/kafkadev01-ehns \
    --metric IncomingMessages \
    --interval PT1M
  ```

## Troubleshooting

- View connector logs: `docker logs kafka-connect --tail 50`
- Delete and recreate: `curl -X DELETE http://localhost:8083/connectors/eventhub-sink`
- Common issues:
  - DNS not resolving: check private endpoint is working (`nslookup <ns>.servicebus.windows.net`)
  - Auth failure: ensure connection string includes full `Endpoint=sb://...` format
  - Topic not created on EH: Event Hub auto-creates topics matching the producer's target topic name
