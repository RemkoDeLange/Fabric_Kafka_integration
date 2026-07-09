#!/bin/bash
set -e

# Run the event generator in the background (venv already set up)
PYTHON=/home/azureuser/venv/bin/python3

cat > /home/azureuser/generator.py << 'PYEOF'
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

def run():
    config = get_config()
    print(f"Starting event generator: {config['events_per_second']} events/sec to {config['topic']}")
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
        running = False
    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    interval = 1.0 / config["events_per_second"]
    total_sent = 0
    while running:
        event = create_event(config)
        producer.produce(topic=config["topic"], key=event["device_id"], value=json.dumps(event))
        total_sent += 1
        producer.poll(0)
        if total_sent % 100 == 0:
            print(f"Sent {total_sent} events")
        time.sleep(interval)
    producer.flush(10)
    print(f"Done. Total sent: {total_sent}")

if __name__ == "__main__":
    run()
PYEOF

# Run in background with nohup
nohup $PYTHON /home/azureuser/generator.py > /home/azureuser/generator.log 2>&1 &
echo "Generator PID: $!"
sleep 3
tail -5 /home/azureuser/generator.log
