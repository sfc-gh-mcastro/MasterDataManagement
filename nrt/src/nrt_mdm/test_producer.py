"""Synthetic event producer for testing the NRT MDM pipeline.

Modes:
  --mode replay      Read existing CSV files and replay as Kafka events
  --mode seed        Generate 100 random events and exit
  --mode continuous  Generate 1 event/sec indefinitely
  --mode burst       Generate N events as fast as possible
"""

import argparse
import csv
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

from confluent_kafka import Producer
from faker import Faker

logger = logging.getLogger(__name__)

fake = Faker()
Faker.seed(42)

TOPIC_CRM_A = "topic.crm.a"
TOPIC_CRM_B = "topic.crm.b"
TOPIC_CRM_C = "topic.crm.c"


def _create_producer() -> Producer:
    return Producer({
        "bootstrap.servers": os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092"),
    })


def _delivery_report(err, msg):
    if err:
        logger.error("Delivery failed: %s", err)


# ---------------------------------------------------------------------------
# Replay mode: read CSVs from batch pipeline output
# ---------------------------------------------------------------------------

def _find_csv_dir() -> Path:
    """Find the output directory with batch CSV files.

    Looks for the shared/output/initial/ structure produced by generate_test_data.py.
    Returns the 'initial' directory containing A/, B/, C/ subdirs.
    """
    # __file__ = .../nrt/src/nrt_mdm/test_producer.py
    # parent^3 = .../nrt/
    # parent^4 = .../MasterDataManagement/ (repo root)
    repo_root = Path(__file__).parent.parent.parent.parent

    candidates = [
        repo_root / "shared" / "output" / "initial",
        repo_root / "bulk" / "output" / "initial",
        Path.cwd() / "shared" / "output" / "initial",
        Path.cwd().parent / "shared" / "output" / "initial",
    ]
    for p in candidates:
        if p.exists() and (p / "A" / "customer").exists():
            return p
    raise FileNotFoundError(
        "Cannot find CSV output directory. Run: python shared/scripts/generate_test_data.py"
    )


def _replay_crm_a(producer: Producer, csv_dir: Path, base_ts: datetime) -> int:
    """Replay CRM_A customer CSVs."""
    count = 0
    for csv_file in sorted((csv_dir / "A" / "customer").glob("*_crm_a_customers.csv")):
        with open(csv_file) as f:
            reader = csv.DictReader(f)
            for row in reader:
                msg = {
                    "src_customer_id": row.get("src_customer_id", row.get("id", "")),
                    "first_name": row.get("first_name"),
                    "last_name": row.get("last_name"),
                    "email": row.get("email"),
                    "phone": row.get("phone"),
                }
                ts_ms = int((base_ts + timedelta(seconds=count)).timestamp() * 1000)
                producer.produce(TOPIC_CRM_A, key=msg["src_customer_id"],
                                 value=json.dumps(msg).encode(),
                                 timestamp=ts_ms, callback=_delivery_report)
                count += 1
    return count


def _replay_crm_b(producer: Producer, csv_dir: Path, base_ts: datetime) -> int:
    """Replay CRM_B customer CSVs."""
    count = 0
    for csv_file in sorted((csv_dir / "B" / "customer").glob("*_crm_b_customers.csv")):
        with open(csv_file) as f:
            reader = csv.DictReader(f)
            for row in reader:
                name = f"{row.get('first_name', '')} {row.get('last_name', '')}".strip()
                if not name or name == " ":
                    name = row.get("name", "")
                msg = {
                    "customer_key": row.get("customer_key", row.get("id", "")),
                    "name": name,
                    "email_address": row.get("email_address", row.get("email", "")),
                    "mobile": row.get("mobile", row.get("phone", "")),
                }
                ts_ms = int((base_ts + timedelta(seconds=count)).timestamp() * 1000)
                producer.produce(TOPIC_CRM_B, key=msg["customer_key"],
                                 value=json.dumps(msg).encode(),
                                 timestamp=ts_ms, callback=_delivery_report)
                count += 1
    return count


def _replay_crm_c(producer: Producer, csv_dir: Path, base_ts: datetime) -> int:
    """Replay CRM_C customer CSVs."""
    count = 0
    for csv_file in sorted((csv_dir / "C" / "customer").glob("*_crm_c_customers.csv")):
        with open(csv_file) as f:
            reader = csv.DictReader(f)
            for row in reader:
                caller_name = f"{row.get('first_name', '')} {row.get('last_name', '')}".strip()
                if not caller_name or caller_name == " ":
                    caller_name = row.get("caller_name", "")
                msg = {
                    "ticket_customer_id": row.get("ticket_customer_id", row.get("id", "")),
                    "caller_name": caller_name,
                    "callback_email": row.get("callback_email", row.get("email", "")),
                    "callback_phone": row.get("callback_phone", row.get("phone", "")),
                }
                ts_ms = int((base_ts + timedelta(seconds=count)).timestamp() * 1000)
                producer.produce(TOPIC_CRM_C, key=msg["ticket_customer_id"],
                                 value=json.dumps(msg).encode(),
                                 timestamp=ts_ms, callback=_delivery_report)
                count += 1
    return count


def mode_replay(producer: Producer):
    """Replay batch CSV files as Kafka events."""
    csv_dir = _find_csv_dir()
    base_ts = datetime.now(timezone.utc) - timedelta(hours=24)

    logger.info("Replaying CSVs from %s", csv_dir)
    total = 0
    total += _replay_crm_a(producer, csv_dir, base_ts)
    total += _replay_crm_b(producer, csv_dir, base_ts + timedelta(seconds=total))
    total += _replay_crm_c(producer, csv_dir, base_ts + timedelta(seconds=total))
    producer.flush()
    logger.info("Replay complete: %d messages produced", total)


# ---------------------------------------------------------------------------
# Seed / Continuous / Burst modes
# ---------------------------------------------------------------------------

def _generate_random_event() -> tuple[str, str, dict]:
    """Generate a random CRM event. Returns (topic, key, payload)."""
    import random
    source = random.choice(["a", "b", "c"])
    key = f"{source.upper()}{random.randint(10000, 99999):05d}"

    if source == "a":
        return TOPIC_CRM_A, key, {
            "src_customer_id": key,
            "first_name": fake.first_name(),
            "last_name": fake.last_name(),
            "email": fake.email(),
            "phone": fake.phone_number(),
        }
    elif source == "b":
        return TOPIC_CRM_B, key, {
            "customer_key": key,
            "name": fake.name(),
            "email_address": fake.email(),
            "mobile": fake.phone_number(),
        }
    else:
        return TOPIC_CRM_C, key, {
            "ticket_customer_id": key,
            "caller_name": fake.name(),
            "callback_email": fake.email(),
            "callback_phone": fake.phone_number(),
        }


def mode_seed(producer: Producer, count: int = 100):
    """Generate N random events and exit."""
    for _ in range(count):
        topic, key, payload = _generate_random_event()
        ts_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        producer.produce(topic, key=key, value=json.dumps(payload).encode(),
                         timestamp=ts_ms, callback=_delivery_report)
    producer.flush()
    logger.info("Seed complete: %d messages produced", count)


def mode_continuous(producer: Producer):
    """Generate 1 event/second indefinitely."""
    logger.info("Continuous mode: 1 event/sec (Ctrl+C to stop)")
    count = 0
    try:
        while True:
            topic, key, payload = _generate_random_event()
            ts_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
            producer.produce(topic, key=key, value=json.dumps(payload).encode(),
                             timestamp=ts_ms, callback=_delivery_report)
            producer.flush()
            count += 1
            time.sleep(1.0)
    except KeyboardInterrupt:
        logger.info("Stopped after %d messages", count)


def mode_burst(producer: Producer, count: int = 1000):
    """Generate N events as fast as possible."""
    start = time.time()
    for _ in range(count):
        topic, key, payload = _generate_random_event()
        ts_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
        producer.produce(topic, key=key, value=json.dumps(payload).encode(),
                         timestamp=ts_ms, callback=_delivery_report)
    producer.flush()
    elapsed = time.time() - start
    logger.info("Burst complete: %d messages in %.2fs (%.0f msg/s)", count, elapsed, count / elapsed if elapsed > 0 else 0)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")

    parser = argparse.ArgumentParser(description="NRT MDM Test Producer")
    parser.add_argument("--mode", choices=["replay", "seed", "continuous", "burst"], default="seed")
    parser.add_argument("--records", type=int, default=100, help="Number of records for seed/burst mode")
    args = parser.parse_args()

    producer = _create_producer()

    if args.mode == "replay":
        mode_replay(producer)
    elif args.mode == "seed":
        mode_seed(producer, args.records)
    elif args.mode == "continuous":
        mode_continuous(producer)
    elif args.mode == "burst":
        mode_burst(producer, args.records)


if __name__ == "__main__":
    main()
