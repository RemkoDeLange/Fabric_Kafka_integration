"""
Kafka-to-Event Hub Bridge using OAuth (Managed Identity).

Consumes from local Kafka (PLAINTEXT) and produces to Azure Event Hubs
using SASL_OAUTHBEARER with the VM's managed identity token.
"""

import json
import os
import signal
import sys
import time
import urllib.request

from confluent_kafka import Consumer, Producer, KafkaError


def get_oauth_token(config_str):
    """Fetch OAuth token from Azure IMDS for Event Hubs scope."""
    resource = "https://kafkadev01a-ehns.servicebus.windows.net"
    url = (
        f"http://169.254.169.254/metadata/identity/oauth2/token"
        f"?api-version=2018-02-01&resource={resource}"
    )
    req = urllib.request.Request(url, headers={"Metadata": "true"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
            return data["access_token"], float(data["expires_on"])
    except Exception as e:
        print(f"ERROR: Failed to get OAuth token: {e}", file=sys.stderr)
        raise


def oauth_cb(config_str):
    """confluent-kafka OAUTHBEARER token callback."""
    token, expiry = get_oauth_token(config_str)
    return token, expiry


def run():
    source_servers = os.environ.get("SOURCE_BOOTSTRAP_SERVERS", "localhost:9092")
    target_servers = os.environ.get("TARGET_BOOTSTRAP_SERVERS",
                                     "kafkadev01a-ehns.servicebus.windows.net:9093")
    topic = os.environ.get("KAFKA_TOPIC", "iot-events")
    consumer_group = os.environ.get("CONSUMER_GROUP", "bridge-group")

    print(f"Kafka-to-Event Hub Bridge (OAuth/MI):")
    print(f"  Source: {source_servers}")
    print(f"  Target: {target_servers}")
    print(f"  Topic:  {topic}")
    print(f"  Group:  {consumer_group}")
    print()

    # Consumer: local Kafka (PLAINTEXT)
    consumer = Consumer({
        "bootstrap.servers": source_servers,
        "group.id": consumer_group,
        "auto.offset.reset": "earliest",
        "enable.auto.commit": True,
        "auto.commit.interval.ms": 5000,
    })

    # Producer: Event Hubs (SASL_OAUTHBEARER)
    producer = Producer({
        "bootstrap.servers": target_servers,
        "security.protocol": "SASL_SSL",
        "sasl.mechanism": "OAUTHBEARER",
        "sasl.oauthbearer.config": "azure",
        "client.id": "kafka-bridge",
        "oauth_cb": oauth_cb,
        "linger.ms": 100,
        "batch.num.messages": 100,
        "request.timeout.ms": 30000,
    })

    consumer.subscribe([topic])

    running = True

    def shutdown(signum, frame):
        nonlocal running
        print("\nShutting down bridge...")
        running = False

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    total_bridged = 0
    errors = 0

    def delivery_cb(err, msg):
        nonlocal errors
        if err:
            errors += 1
            if errors <= 5:
                print(f"ERROR: Delivery failed: {err}", file=sys.stderr)

    print("Bridge running...")
    while running:
        msg = consumer.poll(timeout=1.0)
        if msg is None:
            producer.poll(0)
            continue
        if msg.error():
            if msg.error().code() == KafkaError._PARTITION_EOF:
                continue
            print(f"Consumer error: {msg.error()}", file=sys.stderr)
            continue

        # Forward message to Event Hubs
        producer.produce(
            topic=topic,
            key=msg.key(),
            value=msg.value(),
            callback=delivery_cb,
        )
        total_bridged += 1
        producer.poll(0)

        if total_bridged % 100 == 0:
            print(f"Bridged {total_bridged} events (errors: {errors})")

    # Cleanup
    remaining = producer.flush(timeout=10)
    consumer.close()
    print(f"Done. Total bridged: {total_bridged}, errors: {errors}, unflushed: {remaining}")


if __name__ == "__main__":
    run()
