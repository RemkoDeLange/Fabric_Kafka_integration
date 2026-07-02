#!/bin/bash
set -e

# Setup script for Solution B Kafka (mTLS)
# Run on the VM after infrastructure deployment.
# Downloads certificates from Key Vault and starts Kafka with SSL/mTLS.

KEY_VAULT_NAME="${KEY_VAULT_NAME:-kafkadev01b-kv}"
CERT_DIR="/data/kafka/certs"

echo "=== Solution B: Kafka mTLS Setup ==="

# Ensure directories exist
mkdir -p $CERT_DIR /data/kafka/broker-data
chown -R 1000:1000 /data/kafka/broker-data

# Login with VM managed identity
echo "Logging in with managed identity..."
az login --identity --allow-no-subscriptions

# Download certificates from Key Vault
echo "Downloading certificates from Key Vault: $KEY_VAULT_NAME"
az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "ca-cert" --query value -o tsv > $CERT_DIR/ca-cert.pem
az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "server-cert" --query value -o tsv > $CERT_DIR/server-cert.pem
az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "server-key" --query value -o tsv > $CERT_DIR/server-key.pem
az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "client-cert" --query value -o tsv > $CERT_DIR/client-cert.pem
az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "client-key" --query value -o tsv > $CERT_DIR/client-key.pem

# Set permissions (Kafka runs as UID 1000 in the container)
chmod 644 $CERT_DIR/*.pem
echo "Certificates downloaded to $CERT_DIR"

# Write docker-compose.yml
echo "Writing docker-compose.yml..."
cat > /data/kafka/docker-compose.yml << 'EOF'
services:
  kafka:
    image: apache/kafka:3.7.1
    container_name: kafka
    hostname: kafka
    ports:
      - "9092:9092"
      - "9093:9093"
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9094
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,SSL://0.0.0.0:9093,CONTROLLER://0.0.0.0:9094
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092,SSL://10.1.1.4:9093
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,SSL:SSL,CONTROLLER:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_SSL_KEYSTORE_TYPE: PEM
      KAFKA_SSL_KEYSTORE_LOCATION: /etc/kafka/certs/server-cert.pem
      KAFKA_SSL_KEY_LOCATION: /etc/kafka/certs/server-key.pem
      KAFKA_SSL_TRUSTSTORE_TYPE: PEM
      KAFKA_SSL_TRUSTSTORE_LOCATION: /etc/kafka/certs/ca-cert.pem
      KAFKA_SSL_CLIENT_AUTH: required
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      CLUSTER_ID: MkU3OEVBNTcwNTJENDM2Qk
    volumes:
      - /data/kafka/broker-data:/var/lib/kafka/data
      - /data/kafka/certs:/etc/kafka/certs:ro
EOF

# Start Kafka
echo "Starting Kafka with mTLS..."
cd /data/kafka
docker compose up -d

echo "Waiting for Kafka to start..."
sleep 10

# Create iot-events topic
echo "Creating iot-events topic..."
docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --create --topic iot-events \
  --partitions 4 --replication-factor 1 \
  --if-not-exists

echo ""
echo "=== Setup complete ==="
echo "PLAINTEXT listener: localhost:9092 (for event-generator on VM)"
echo "SSL/mTLS listener:  10.1.1.4:9093 (for Fabric Eventstream connector)"
echo ""
echo "Test mTLS connection:"
echo "  docker exec kafka /opt/kafka/bin/kafka-broker-api-versions.sh \\"
echo "    --bootstrap-server 10.1.1.4:9093 \\"
echo "    --command-config /etc/kafka/certs/client.properties"
