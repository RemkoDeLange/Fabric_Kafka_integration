#!/bin/bash
set -e

# Create event-generator directory
mkdir -p /home/azureuser/event-generator
cd /home/azureuser/event-generator

# Write requirements.txt
cat > requirements.txt << 'EOF'
confluent-kafka>=2.3.0
EOF

# Write generator.py
cat > generator.py << 'PYEOF'
"""Event Generator - Simulates IoT device telemetry and produces to Kafka."""
import json
import os
import random
import signal
import sys
import time
from datetime import datetime, timezone
from confluent_kafka import Producer

def get_config():
    return {
        "bootstrap_servers": os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092"),
        "topic": os.environ.get("KAFKA_TOPIC", "iot-events"),
        "events_per_second": int(os.environ.get("EVENTS_PER_SECOND", "10")),
        "num_devices": int(os.environ.get("NUM_DEVICES", "50")),
        "locations": os.environ.get("LOCATIONS", "warehouse-A,warehouse-B,office-1,lab-3").split(","),
    }

def create_event(config):
    device_id = f"device-{random.randint(1, config['num_devices']):03d}"
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "device_id": device_id,
        "temperature": round(random.uniform(15.0, 35.0), 1),
        "humidity": round(random.uniform(30.0, 90.0), 1),
        "location": random.choice(config["locations"]),
    }

def delivery_callback(err, msg):
    if err is not None:
        print(f"ERROR: Delivery failed: {err}", file=sys.stderr)

def run():
    config = get_config()
    print(f"Starting event generator:")
    print(f"  Kafka: {config['bootstrap_servers']}")
    print(f"  Topic: {config['topic']}")
    print(f"  Rate:  {config['events_per_second']} events/sec")
    print(f"  Devices: {config['num_devices']}")
    print()
    producer = Producer({
        "bootstrap.servers": config["bootstrap_servers"],
        "client.id": "event-generator",
        "acks": "all",
        "linger.ms": 100,
        "batch.num.messages": 100,
    })
    running = True
    def shutdown(signum, frame):
        nonlocal running
        print("\nShutting down...")
        running = False
    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    interval = 1.0 / config["events_per_second"]
    total_sent = 0
    while running:
        event = create_event(config)
        producer.produce(
            topic=config["topic"],
            key=event["device_id"],
            value=json.dumps(event),
            callback=delivery_callback,
        )
        total_sent += 1
        producer.poll(0)
        if total_sent % 100 == 0:
            print(f"Sent {total_sent} events (latest: {event['device_id']} temp={event['temperature']}C)")
        time.sleep(interval)
    remaining = producer.flush(timeout=10)
    print(f"Done. Total sent: {total_sent}, unflushed: {remaining}")

if __name__ == "__main__":
    run()
PYEOF

# Write Dockerfile
cat > Dockerfile << 'DEOF'
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc librdkafka-dev && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY generator.py .
ENV KAFKA_BOOTSTRAP_SERVERS=kafka:9092
ENV KAFKA_TOPIC=iot-events
ENV EVENTS_PER_SECOND=10
ENV NUM_DEVICES=50
CMD ["python", "-u", "generator.py"]
DEOF

# Build and run
echo "Building event-generator image..."
docker build -t event-generator . 2>&1

echo "Starting event-generator container..."
docker run -d --name event-generator \
  --network kafka_default \
  -e KAFKA_BOOTSTRAP_SERVERS=kafka:9092 \
  -e KAFKA_TOPIC=iot-events \
  -e EVENTS_PER_SECOND=5 \
  -e NUM_DEVICES=20 \
  --restart unless-stopped \
  event-generator 2>&1

echo "---CONTAINER_STARTED---"
sleep 10
docker logs event-generator --tail 20 2>&1
