#!/usr/bin/env python3
"""Batch re-resolution CLI.

Re-resolves all source records from scratch. Used for:
- Initial bulk load from batch Snowflake pipeline
- Full cluster rebuild after schema/rule changes
- Disaster recovery

Usage:
  python -m nrt_mdm.batch_resolve [--reset]
"""

import argparse
import logging
import os
import time

import psycopg
from confluent_kafka import Producer

from nrt_mdm.dq import compute_dq_score
from nrt_mdm.models import SourceCustomer
from nrt_mdm.producer import publish_golden_if_changed
from nrt_mdm.resolver import resolve
from nrt_mdm.survivorship import compute_golden

logger = logging.getLogger(__name__)

FETCH_ALL_SOURCES_SQL = """
SELECT source_system, source_key, first_name, last_name,
       canonical_first_name, email, phone,
       block_soundex, block_email_domain, block_phone_suffix,
       event_timestamp
FROM source_customers
ORDER BY event_timestamp ASC
"""

RESET_CLUSTER_SQL = "TRUNCATE customer_clusters, golden_customers, customer_xref RESTART IDENTITY"


def batch_resolve(reset: bool = False):
    """Re-resolve all source records sequentially."""
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")

    dsn = os.environ.get("POSTGRES_DSN", "postgresql://mdm:mdm@localhost:5432/mdm")
    conn = psycopg.connect(dsn, autocommit=False)

    producer = Producer({
        "bootstrap.servers": os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092"),
        "acks": "all",
        "enable.idempotence": True,
    })

    if reset:
        logger.info("Resetting clusters, golden records, and XREF...")
        with conn.cursor() as cur:
            cur.execute(RESET_CLUSTER_SQL)
        conn.commit()

    # Fetch all source records
    with conn.cursor() as cur:
        cur.execute(FETCH_ALL_SOURCES_SQL)
        rows = cur.fetchall()

    logger.info("Re-resolving %d source records...", len(rows))
    start = time.time()
    processed = 0
    clusters_affected: set[int] = set()

    for row in rows:
        record = SourceCustomer(
            source_system=row[0],
            source_key=row[1],
            first_name=row[2],
            last_name=row[3],
            canonical_first_name=row[4],
            email=row[5],
            phone=row[6],
            block_soundex=row[7],
            block_email_domain=row[8],
            block_phone_suffix=row[9],
            event_timestamp=row[10],
        )

        cluster_id, _ = resolve(conn, record)
        clusters_affected.add(cluster_id)
        processed += 1

        if processed % 100 == 0:
            conn.commit()
            logger.info("  processed %d/%d records...", processed, len(rows))

    conn.commit()

    # Recompute golden records for all affected clusters
    logger.info("Recomputing golden records for %d clusters...", len(clusters_affected))
    golden_count = 0
    for cluster_id in clusters_affected:
        golden = compute_golden(conn, cluster_id)
        if golden:
            golden.dq_score = compute_dq_score(golden)
            publish_golden_if_changed(producer, conn, golden)
            golden_count += 1

    conn.commit()
    producer.flush()

    elapsed = time.time() - start
    logger.info(
        "Batch re-resolution complete: %d records -> %d clusters -> %d golden records (%.1fs)",
        processed, len(clusters_affected), golden_count, elapsed,
    )

    conn.close()


def main():
    parser = argparse.ArgumentParser(description="Batch re-resolution CLI")
    parser.add_argument("--reset", action="store_true", help="Truncate clusters/golden/xref before re-resolving")
    args = parser.parse_args()
    batch_resolve(reset=args.reset)


if __name__ == "__main__":
    main()
