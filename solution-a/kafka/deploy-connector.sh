#!/bin/bash
set -e

# Deploy Kafka Connect MirrorSourceConnector with OAuth/OAUTHBEARER authentication
# The VM's managed identity is assigned "Azure Event Hubs Data Sender" role via Bicep.
#
# Required environment variables:
#   EVENTHUB_NAMESPACE  - Event Hub namespace (e.g., kafkadev01-ehns)
#   TENANT_ID           - Azure AD tenant ID
#   CLIENT_ID           - Service principal app (client) ID
#   CLIENT_SECRET       - Service principal secret
#
# For Managed Identity (zero-secret), set USE_MANAGED_IDENTITY=true instead of CLIENT_ID/SECRET.

EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE:-kafkadev01-ehns}"
TENANT_ID="${TENANT_ID}"
CLIENT_ID="${CLIENT_ID}"
CLIENT_SECRET="${CLIENT_SECRET}"
USE_MANAGED_IDENTITY="${USE_MANAGED_IDENTITY:-false}"

if [ "$USE_MANAGED_IDENTITY" = "true" ]; then
  echo "Using VM Managed Identity for OAuth (requires azure-identity JAR in Connect classpath)"
  # Managed Identity requires a custom callback handler JAR - documented in README
  JAAS_CONFIG="org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;"
  LOGIN_CALLBACK="org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler"
  TOKEN_ENDPOINT="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"
else
  if [ -z "$TENANT_ID" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
    echo "ERROR: Set TENANT_ID, CLIENT_ID, CLIENT_SECRET (or USE_MANAGED_IDENTITY=true)"
    exit 1
  fi
  JAAS_CONFIG="org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId=\\\"${CLIENT_ID}\\\" clientSecret=\\\"${CLIENT_SECRET}\\\" scope=\\\"https://${EVENTHUB_NAMESPACE}.servicebus.windows.net/.default\\\";"
  LOGIN_CALLBACK="org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler"
  TOKEN_ENDPOINT="https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token"
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

# Deploy the MirrorSourceConnector with OAUTHBEARER
echo "Deploying eventhub-sink connector (OAuth/OAUTHBEARER)..."
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
      \"target.cluster.bootstrap.servers\": \"${EVENTHUB_NAMESPACE}.servicebus.windows.net:9093\",
      \"target.cluster.security.protocol\": \"SASL_SSL\",
      \"target.cluster.sasl.mechanism\": \"OAUTHBEARER\",
      \"target.cluster.sasl.jaas.config\": \"${JAAS_CONFIG}\",
      \"target.cluster.sasl.login.callback.handler.class\": \"${LOGIN_CALLBACK}\",
      \"target.cluster.sasl.oauthbearer.token.endpoint.url\": \"${TOKEN_ENDPOINT}\",
      \"target.cluster.sasl.oauthbearer.scope\": \"https://${EVENTHUB_NAMESPACE}.servicebus.windows.net/.default\",
      \"replication.policy.class\": \"org.apache.kafka.connect.mirror.IdentityReplicationPolicy\",
      \"replication.policy.separator\": \"\",
      \"sync.topic.acls.enabled\": \"false\",
      \"sync.topic.configs.enabled\": \"false\",
      \"refresh.topics.interval.seconds\": \"60\",
      \"producer.override.security.protocol\": \"SASL_SSL\",
      \"producer.override.sasl.mechanism\": \"OAUTHBEARER\",
      \"producer.override.sasl.jaas.config\": \"${JAAS_CONFIG}\",
      \"producer.override.sasl.login.callback.handler.class\": \"${LOGIN_CALLBACK}\",
      \"producer.override.sasl.oauthbearer.token.endpoint.url\": \"${TOKEN_ENDPOINT}\",
      \"producer.override.sasl.oauthbearer.scope\": \"https://${EVENTHUB_NAMESPACE}.servicebus.windows.net/.default\",
      \"producer.override.max.request.size\": \"1048576\",
      \"producer.override.request.timeout.ms\": \"30000\"
    }
  }"

echo ""
echo "Connector deployed. Checking status..."
sleep 5

# Check connector status
curl -sf http://localhost:8083/connectors/eventhub-sink/status | python3 -m json.tool 2>/dev/null || curl -sf http://localhost:8083/connectors/eventhub-sink/status
