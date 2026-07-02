"""
Event Generator — Simulates IoT device telemetry and produces to Kafka.
Solution B variant: connects via PLAINTEXT to local Kafka (same VM).

For mTLS testing, set KAFKA_SECURITY_PROTOCOL=SSL and provide cert paths.

Generates JSON events like:
{
    "timestamp": "2026-06-29T14:30:00.123Z",
    "device_id": "device-042",
    "temperature": 22.5,
    "humidity": 65.3,
    "location": "warehouse-A"
}
"""

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
        "events_per_second": int(os.environ.get("EVENTS_PER_SECOND", "5")),
        "num_devices": int(os.environ.get("NUM_DEVICES", "50")),
        "locations": os.environ.get("LOCATIONS", "warehouse-A,warehouse-B,office-1,lab-3").split(","),
        "security_protocol": os.environ.get("KAFKA_SECURITY_PROTOCOL", "PLAINTEXT"),
        "ssl_ca_location": os.environ.get("KAFKA_SSL_CA_LOCATION", ""),
        "ssl_certificate_location": os.environ.get("KAFKA_SSL_CERTIFICATE_LOCATION", ""),
        "ssl_key_location": os.environ.get("KAFKA_SSL_KEY_LOCATION", ""),
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
    print(f"Starting event generator (Solution B):")
    print(f"  Kafka: {config['bootstrap_servers']}")
    print(f"  Topic: {config['topic']}")
    print(f"  Rate:  {config['events_per_second']} events/sec")
    print(f"  Security: {config['security_protocol']}")
    print()

    producer_config = {
        "bootstrap.servers": config["bootstrap_servers"],
        "client.id": "event-generator-b",
        "acks": "all",
        "linger.ms": 100,
        "batch.num.messages": 100,
        "security.protocol": config["security_protocol"],
    }

    # Add SSL/mTLS config if using SSL protocol
    if config["security_protocol"] == "SSL":
        producer_config["ssl.ca.location"] = config["ssl_ca_location"]
        producer_config["ssl.certificate.location"] = config["ssl_certificate_location"]
        producer_config["ssl.key.location"] = config["ssl_key_location"]

    producer = Producer(producer_config)

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
            print(f"Sent {total_sent} events (latest: {event['device_id']} temp={event['temperature']}°C)")

        time.sleep(interval)

    remaining = producer.flush(timeout=10)
    print(f"Done. Total sent: {total_sent}, unflushed: {remaining}")


if __name__ == "__main__":
    run()
