#!/bin/bash
set -e

# Stop existing container
docker-compose -f /data/kafka/docker-compose.yml down 2>/dev/null || docker stop kafka 2>/dev/null; docker rm kafka 2>/dev/null || true

# Convert PEM certs to PKCS12 format (required by apache/kafka image's configure script)
CERTS_DIR=/data/kafka/certs
SECRETS_DIR=/data/kafka/secrets
mkdir -p "$SECRETS_DIR"

STORE_PASS="kafkassl123"

# Create PKCS12 keystore from server cert + key
openssl pkcs12 -export \
  -in "$CERTS_DIR/server-cert.pem" \
  -inkey "$CERTS_DIR/server-key.pem" \
  -CAfile "$CERTS_DIR/ca-cert.pem" \
  -name kafka-server \
  -out "$SECRETS_DIR/kafka.keystore.p12" \
  -password "pass:$STORE_PASS"

# Create PKCS12 truststore from CA cert
# Note: keytool from the container is used post-start to create a proper truststore
# openssl pkcs12 -export alone creates empty truststores for CA-only imports
echo "$STORE_PASS" > "$SECRETS_DIR/truststore_creds"

# Create credential files
echo "$STORE_PASS" > "$SECRETS_DIR/keystore_creds"
echo "$STORE_PASS" > "$SECRETS_DIR/key_creds"
echo "$STORE_PASS" > "$SECRETS_DIR/truststore_creds"

chmod 644 "$SECRETS_DIR"/*

# Write fixed docker-compose.yml
cat > /data/kafka/docker-compose.yml << 'COMPOSEEOF'
version: "3"
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
      KAFKA_SSL_KEYSTORE_FILENAME: kafka.keystore.p12
      KAFKA_SSL_KEYSTORE_CREDENTIALS: keystore_creds
      KAFKA_SSL_KEY_CREDENTIALS: key_creds
      KAFKA_SSL_KEYSTORE_TYPE: PKCS12
      KAFKA_SSL_TRUSTSTORE_FILENAME: kafka.truststore.p12
      KAFKA_SSL_TRUSTSTORE_CREDENTIALS: truststore_creds
      KAFKA_SSL_TRUSTSTORE_TYPE: PKCS12
      KAFKA_SSL_CLIENT_AUTH: required
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      CLUSTER_ID: MkU3OEVBNTcwNTJENDM2Qk
    volumes:
      - /data/kafka/broker-data:/var/lib/kafka/data
      - /data/kafka/secrets:/etc/kafka/secrets:ro
    restart: unless-stopped
COMPOSEEOF

cd /data/kafka
docker-compose up -d

echo "Waiting for Kafka..."
for i in $(seq 1 30); do
  if docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list > /dev/null 2>&1; then
    echo "Kafka ready!"
    break
  fi
  sleep 5
done

# Create proper PKCS12 truststore using keytool from inside the container
docker cp "$CERTS_DIR/ca-cert.pem" kafka:/tmp/ca-cert.pem
docker exec kafka rm -f /tmp/kafka.truststore.p12
docker exec kafka keytool -importcert -noprompt -alias ca-cert \
  -file /tmp/ca-cert.pem -keystore /tmp/kafka.truststore.p12 \
  -storetype PKCS12 -storepass "$STORE_PASS"
docker cp kafka:/tmp/kafka.truststore.p12 "$SECRETS_DIR/kafka.truststore.p12"
chmod 644 "$SECRETS_DIR/kafka.truststore.p12"

# Restart to pick up the fixed truststore
docker-compose -f /data/kafka/docker-compose.yml restart kafka
echo "Waiting for Kafka after truststore fix..."
for i in $(seq 1 30); do
  if docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list > /dev/null 2>&1; then
    echo "Kafka ready with mTLS!"
    break
  fi
  sleep 5
done

# Create topic
docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --topic iot-events --partitions 4 --replication-factor 1 --if-not-exists

docker-compose ps
docker logs kafka 2>&1 | tail -5
