#!/bin/bash
set -e

# Usage: EVENTHUB_CONNECTION_STRING="Endpoint=sb://..." ./deploy-connector.sh
if [ -z "$EVENTHUB_CONNECTION_STRING" ]; then
  echo "ERROR: Set EVENTHUB_CONNECTION_STRING environment variable before running."
  echo "  export EVENTHUB_CONNECTION_STRING='Endpoint=sb://kafkadev01-ehns...'"
  exit 1
fi

# Create the iot-events topic
echo "Creating iot-events topic..."
docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create --topic iot-events \
  --partitions 4 --replication-factor 1 \
  --if-not-exists

echo "Topic created."

# Wait for Connect REST API
echo "Waiting for Kafka Connect REST API..."
for i in $(seq 1 20); do
  if curl -sf http://localhost:8083/connectors > /dev/null 2>&1; then
    echo "Connect REST is ready!"
    break
  fi
  sleep 3
done

# Deploy the MirrorSourceConnector
echo "Deploying eventhub-sink connector..."
curl -sf -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"eventhub-sink\",
    \"config\": {
      \"connector.class\": \"org.apache.kafka.connect.mirror.MirrorSourceConnector\",
      \"tasks.max\": \"1\",
      \"topics\": \"iot-events\",
      \"source.cluster.alias\": \"local\",
      \"source.cluster.bootstrap.servers\": \"kafka:9092\",
      \"target.cluster.alias\": \"eventhub\",
      \"target.cluster.bootstrap.servers\": \"kafkadev01-ehns.servicebus.windows.net:9093\",
      \"target.cluster.security.protocol\": \"SASL_SSL\",
      \"target.cluster.sasl.mechanism\": \"PLAIN\",
      \"target.cluster.sasl.jaas.config\": \"org.apache.kafka.common.security.plain.PlainLoginModule required username=\\\"\\\$ConnectionString\\\" password=\\\"${EVENTHUB_CONNECTION_STRING}\\\";\",
      \"replication.policy.class\": \"org.apache.kafka.connect.mirror.IdentityReplicationPolicy\",
      \"replication.policy.separator\": \"\",
      \"sync.topic.acls.enabled\": \"false\",
      \"sync.topic.configs.enabled\": \"false\",
      \"refresh.topics.interval.seconds\": \"60\",
      \"producer.override.security.protocol\": \"SASL_SSL\",
      \"producer.override.sasl.mechanism\": \"PLAIN\",
      \"producer.override.sasl.jaas.config\": \"org.apache.kafka.common.security.plain.PlainLoginModule required username=\\\"\\\$ConnectionString\\\" password=\\\"${EVENTHUB_CONNECTION_STRING}\\\";\",
      \"producer.override.max.request.size\": \"1048576\",
      \"producer.override.request.timeout.ms\": \"30000\"
    }
  }"

echo ""
echo "Connector deployed. Checking status..."
sleep 5

# Check connector status
curl -sf http://localhost:8083/connectors/eventhub-sink/status | python3 -m json.tool 2>/dev/null || curl -sf http://localhost:8083/connectors/eventhub-sink/status
