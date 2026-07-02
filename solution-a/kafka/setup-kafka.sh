#!/bin/bash
set -e

mkdir -p /home/azureuser/kafka/kafka-connect/plugins
cd /home/azureuser/kafka

# Write docker-compose.yml
cat > docker-compose.yml << 'EOF'
services:
  kafka:
    image: apache/kafka:3.7.1
    container_name: kafka
    hostname: kafka
    ports:
      - "9092:9092"
    environment:
      KAFKA_NODE_ID: "1"
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://10.0.1.4:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      CLUSTER_ID: MkU3OEVBNTcwNTJENDM2Qk
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      KAFKA_LOG_RETENTION_HOURS: "24"
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      KAFKA_NUM_PARTITIONS: "4"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: "1"
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: "1"
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: "1"
    volumes:
      - /data/kafka/broker-data:/var/lib/kafka/data
    healthcheck:
      test: ["CMD-SHELL", "/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped

  kafka-connect:
    image: apache/kafka:3.7.1
    container_name: kafka-connect
    hostname: kafka-connect
    ports:
      - "8083:8083"
    command: >
      bash -c "
        echo 'Waiting for Kafka...' &&
        while ! /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list > /dev/null 2>&1; do sleep 2; done &&
        echo 'Starting Connect...' &&
        cat > /tmp/connect.properties << 'PROPS'
        bootstrap.servers=kafka:9092
        group.id=connect-cluster
        key.converter=org.apache.kafka.connect.storage.StringConverter
        value.converter=org.apache.kafka.connect.json.JsonConverter
        value.converter.schemas.enable=false
        config.storage.topic=_connect-configs
        offset.storage.topic=_connect-offsets
        status.storage.topic=_connect-status
        config.storage.replication.factor=1
        offset.storage.replication.factor=1
        status.storage.replication.factor=1
        plugin.path=/opt/kafka/plugins
        rest.advertised.host.name=kafka-connect
      PROPS
        /opt/kafka/bin/connect-distributed.sh /tmp/connect.properties
      "
    volumes:
      - ./kafka-connect/plugins:/opt/kafka/plugins
    depends_on:
      kafka:
        condition: service_healthy
    restart: unless-stopped
EOF

chown -R 1000:1000 /data/kafka
mkdir -p /data/kafka/broker-data
chown 1000:1000 /data/kafka/broker-data

docker compose pull
docker compose up -d

echo "Waiting for Kafka health..."
for i in $(seq 1 30); do
  if docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list > /dev/null 2>&1; then
    echo "Kafka is ready!"
    break
  fi
  sleep 5
done

docker compose ps
docker exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2>&1 || true
