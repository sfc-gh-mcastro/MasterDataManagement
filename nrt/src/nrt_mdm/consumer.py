"""Kafka consumer loop: single-message processing orchestration.

Polls one message at a time, maps, UPSERTs, resolves, and publishes.
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone

import psycopg
from confluent_kafka import Consumer, Producer, KafkaError

from nrt_mdm.dq import compute_dq_score
from nrt_mdm.mappers import TOPIC_MAPPER
from nrt_mdm.producer import publish_golden_if_changed, publish_xref_change
from nrt_mdm.resolver import resolve
from nrt_mdm.survivorship import compute_golden
from nrt_mdm.upsert import upsert_source_customer

logger = logging.getLogger(__name__)


def _create_consumer() -> Consumer:
    return Consumer({
        "bootstrap.servers": os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092"),
        "group.id": os.environ.get("KAFKA_GROUP_ID", "nrt-mdm-consumer"),
        "auto.offset.reset": "earliest",
        "enable.auto.commit": False,
    })


def _create_producer() -> Producer:
    return Producer({
        "bootstrap.servers": os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092"),
        "acks": "all",
        "enable.idempotence": True,
        "retries": 3,
    })


def _get_pg_conn():
    dsn = os.environ.get("POSTGRES_DSN", "postgresql://mdm:mdm@localhost:5432/mdm")
    conn = psycopg.connect(dsn, autocommit=False)
    return conn


def process_message(msg, pg_conn, producer) -> None:
    """Process a single Kafka message through the full MDM pipeline."""
    topic = msg.topic()
    mapper = TOPIC_MAPPER.get(topic)

    if mapper is None:
        logger.warning("No mapper for topic %s, skipping", topic)
        return

    # Parse payload
    try:
        payload = json.loads(msg.value())
    except (json.JSONDecodeError, TypeError) as e:
        logger.error("Malformed JSON on topic %s: %s", topic, e)
        return

    # Extract event_timestamp from Kafka message timestamp
    ts_type, ts_ms = msg.timestamp()
    event_ts = datetime.fromtimestamp(ts_ms / 1000.0, tz=timezone.utc)

    # Map to common schema
    record = mapper(payload, event_ts)

    # UPSERT into source_customers (with out-of-order protection)
    updated = upsert_source_customer(pg_conn, record)

    if not updated:
        # Out-of-order message -- older than current state, skip resolution
        pg_conn.commit()
        return

    # Resolve: blocking + matching + clustering
    cluster_id, cluster_changed = resolve(pg_conn, record)

    # Recompute golden record for affected cluster
    golden = compute_golden(pg_conn, cluster_id)
    if golden is None:
        pg_conn.commit()
        return

    # Compute DQ score
    golden.dq_score = compute_dq_score(golden)

    # CDC: publish golden if changed (includes SCD2 write)
    publish_golden_if_changed(producer, pg_conn, golden)

    # Publish XREF change if this is a new assignment
    if cluster_changed:
        publish_xref_change(producer, record.source_system, record.source_key, cluster_id)

    # Commit DB transaction
    pg_conn.commit()


def run_consumer():
    """Main consumer loop. Polls one message at a time."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    consumer = _create_consumer()
    producer = _create_producer()
    pg_conn = _get_pg_conn()

    topics = list(TOPIC_MAPPER.keys())
    consumer.subscribe(topics)
    logger.info("Subscribed to topics: %s", topics)

    try:
        while True:
            msg = consumer.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    continue
                logger.error("Consumer error: %s", msg.error())
                continue

            try:
                process_message(msg, pg_conn, producer)
                consumer.commit(message=msg)
            except Exception:
                logger.exception("Error processing message from %s", msg.topic())
                pg_conn.rollback()

    except KeyboardInterrupt:
        logger.info("Shutting down consumer")
    finally:
        consumer.close()
        pg_conn.close()


if __name__ == "__main__":
    run_consumer()
