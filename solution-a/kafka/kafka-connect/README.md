# Kafka Connect — Event Hub Sink Setup

## Overview

Uses Kafka's built-in MirrorSourceConnector to replicate events from the local Kafka topic
to Azure Event Hub (which speaks Kafka protocol natively on port 9093).

The connector replicates the `iot-events` topic to an Event Hub entity with the same name.

**Important configuration notes:**

- **ByteArrayConverter** must be set for both `key.converter` and `value.converter` to ensure
  raw JSON messages are forwarded without base64 encoding.
- **`producer.override.bootstrap.servers`** must explicitly point to the Event Hub endpoint.
  Without this, the producer falls back to the Connect worker's local bootstrap servers.
- The `iot-events` Event Hub entity must be **pre-created** — the SAS policy (Send+Listen)
  does not include Manage rights needed for auto-creation via Kafka protocol.

## Prerequisites

1. Kafka + Kafka Connect running (via `setup-kafka.sh` or `docker-compose.yml`)
2. Event Hub entity `iot-events` created:
   ```bash
   az eventhubs eventhub create \
     --resource-group <rg> \
     --namespace-name <namespace> \
     --name iot-events \
     --partition-count 4 \
     --cleanup-policy Delete \
     --retention-time-in-hours 24
   ```
3. Event Hub connection string:
   ```bash
   az eventhubs namespace authorization-rule keys list \
     --resource-group <rg> \
     --namespace-name <namespace> \
     --name KafkaConnectPolicy \
     --query primaryConnectionString -o tsv
   ```

## Deploy the Connector

1. Edit `eventhub-sink.json`:
   - Replace `${EVENTHUB_NAMESPACE}` with your namespace name (e.g., `kafkadev01a-ehns`)
   - Replace `${EVENTHUB_CONNECTION_STRING}` with the full connection string from above

2. Submit to Kafka Connect REST API:
   ```bash
   curl -X POST http://localhost:8083/connectors \
     -H "Content-Type: application/json" \
     -d @eventhub-sink.json
   ```

3. Check status:
   ```bash
   curl http://localhost:8083/connectors/eventhub-mirror/status | jq
   ```

## Verify

- Check connector commit log:
  ```bash
  docker logs kafka-connect --tail 10 2>&1 | grep 'Committing offsets'
  ```
- Check Event Hub metrics:
  ```bash
  az monitor metrics list \
    --resource /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.EventHub/namespaces/<namespace> \
    --metric IncomingMessages \
    --interval PT1M \
    --query "value[0].timeseries[0].data[-3:]" -o table
  ```

## Troubleshooting

- View connector logs: `docker logs kafka-connect --tail 50`
- Delete and recreate: `curl -X DELETE http://localhost:8083/connectors/eventhub-sink`
- Common issues:
  - DNS not resolving: check private endpoint is working (`nslookup <ns>.servicebus.windows.net`)
  - Auth failure: ensure connection string includes full `Endpoint=sb://...` format
  - Topic not created on EH: Event Hub auto-creates topics matching the producer's target topic name
