FROM python:3.12-slim

WORKDIR /app

# Install librdkafka dependency for confluent-kafka
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc librdkafka-dev && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY generator.py .

# Default configuration (override via environment variables)
ENV KAFKA_BOOTSTRAP_SERVERS=kafka:9092
ENV KAFKA_TOPIC=iot-events
ENV EVENTS_PER_SECOND=10
ENV NUM_DEVICES=50

CMD ["python", "-u", "generator.py"]
