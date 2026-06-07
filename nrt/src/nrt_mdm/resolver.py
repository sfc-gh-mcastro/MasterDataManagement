"""Cluster manager: blocking, candidate lookup, matching, and Union-Find clustering."""

from nrt_mdm.matching import compute_match_score, MATCH_THRESHOLD
from nrt_mdm.models import SourceCustomer


# ---------------------------------------------------------------------------
# Blocking: candidate lookup via indexed columns
# ---------------------------------------------------------------------------

FIND_CANDIDATES_SQL = """
SELECT source_system, source_key, first_name, last_name,
       canonical_first_name, email, phone,
       block_soundex, block_email_domain, block_phone_suffix,
       event_timestamp
FROM source_customers
WHERE (source_system, source_key) != (%(source_system)s, %(source_key)s)
  AND (
      (block_soundex = %(block_soundex)s AND %(block_soundex)s IS NOT NULL)
      OR (block_email_domain = %(block_email_domain)s AND %(block_email_domain)s IS NOT NULL)
      OR (block_phone_suffix = %(block_phone_suffix)s AND %(block_phone_suffix)s IS NOT NULL)
  )
"""


def find_candidates(conn, record: SourceCustomer) -> list[SourceCustomer]:
    """Find potential matches using blocking keys. O(block_size) not O(N)."""
    params = {
        "source_system": record.source_system,
        "source_key": record.source_key,
        "block_soundex": record.block_soundex,
        "block_email_domain": record.block_email_domain,
        "block_phone_suffix": record.block_phone_suffix,
    }
    with conn.cursor() as cur:
        cur.execute(FIND_CANDIDATES_SQL, params)
        rows = cur.fetchall()

    candidates = []
    for row in rows:
        candidates.append(SourceCustomer(
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
        ))
    return candidates


# ---------------------------------------------------------------------------
# Cluster lookup and management
# ---------------------------------------------------------------------------

GET_CLUSTER_SQL = """
SELECT cluster_id FROM customer_clusters
WHERE source_system = %(source_system)s AND source_key = %(source_key)s
"""

GET_CLUSTER_FOR_RECORD_SQL = """
SELECT cluster_id FROM customer_clusters
WHERE source_system = %(source_system)s AND source_key = %(source_key)s
"""

CREATE_CLUSTER_SQL = """
INSERT INTO customer_clusters (source_system, source_key, cluster_id)
VALUES (%(source_system)s, %(source_key)s, nextval('cluster_seq'))
RETURNING cluster_id
"""

ASSIGN_TO_CLUSTER_SQL = """
INSERT INTO customer_clusters (source_system, source_key, cluster_id)
VALUES (%(source_system)s, %(source_key)s, %(cluster_id)s)
ON CONFLICT (source_system, source_key) DO UPDATE SET cluster_id = EXCLUDED.cluster_id
"""

MERGE_CLUSTERS_SQL = """
UPDATE customer_clusters SET cluster_id = %(target_id)s
WHERE cluster_id = %(source_id)s
"""

CLUSTER_SIZE_SQL = """
SELECT COUNT(*) FROM customer_clusters WHERE cluster_id = %(cluster_id)s
"""

UPSERT_XREF_SQL = """
INSERT INTO customer_xref (source_system, source_key, customer_id)
VALUES (%(source_system)s, %(source_key)s, %(customer_id)s)
ON CONFLICT (source_system, source_key) DO UPDATE SET
    customer_id = EXCLUDED.customer_id,
    created_at = NOW()
"""

UPDATE_XREF_FOR_CLUSTER_SQL = """
UPDATE customer_xref SET customer_id = %(new_id)s, created_at = NOW()
WHERE customer_id = %(old_id)s
"""


def get_cluster_id(conn, source_system: str, source_key: str) -> int | None:
    """Get the cluster_id for a source record, or None if not clustered yet."""
    with conn.cursor() as cur:
        cur.execute(GET_CLUSTER_SQL, {"source_system": source_system, "source_key": source_key})
        row = cur.fetchone()
        return row[0] if row else None


def create_new_cluster(conn, source_system: str, source_key: str) -> int:
    """Create a new cluster for a record that has no matches."""
    with conn.cursor() as cur:
        cur.execute(CREATE_CLUSTER_SQL, {"source_system": source_system, "source_key": source_key})
        cluster_id = cur.fetchone()[0]
    # Update XREF
    with conn.cursor() as cur:
        cur.execute(UPSERT_XREF_SQL, {"source_system": source_system, "source_key": source_key, "customer_id": cluster_id})
    return cluster_id


def assign_to_cluster(conn, source_system: str, source_key: str, cluster_id: int) -> None:
    """Assign a source record to an existing cluster."""
    with conn.cursor() as cur:
        cur.execute(ASSIGN_TO_CLUSTER_SQL, {"source_system": source_system, "source_key": source_key, "cluster_id": cluster_id})
        cur.execute(UPSERT_XREF_SQL, {"source_system": source_system, "source_key": source_key, "customer_id": cluster_id})


def merge_clusters(conn, cluster_a: int, cluster_b: int) -> int:
    """Merge two clusters. Smaller cluster is absorbed into larger. Returns surviving cluster_id."""
    with conn.cursor() as cur:
        cur.execute(CLUSTER_SIZE_SQL, {"cluster_id": cluster_a})
        size_a = cur.fetchone()[0]
        cur.execute(CLUSTER_SIZE_SQL, {"cluster_id": cluster_b})
        size_b = cur.fetchone()[0]

    if size_a >= size_b:
        target, source = cluster_a, cluster_b
    else:
        target, source = cluster_b, cluster_a

    with conn.cursor() as cur:
        cur.execute(MERGE_CLUSTERS_SQL, {"target_id": target, "source_id": source})
        cur.execute(UPDATE_XREF_FOR_CLUSTER_SQL, {"new_id": target, "old_id": source})

    return target


# ---------------------------------------------------------------------------
# Resolution orchestration
# ---------------------------------------------------------------------------

def resolve(conn, record: SourceCustomer) -> tuple[int, bool]:
    """Resolve a record: find matches, assign/merge clusters.

    Returns (cluster_id, cluster_changed) where cluster_changed indicates
    whether a new cluster was created or an existing one was modified.
    """
    candidates = find_candidates(conn, record)

    # Score against all candidates, collect matches
    matched_clusters: set[int] = set()
    for candidate in candidates:
        if compute_match_score(record, candidate) >= MATCH_THRESHOLD:
            cid = get_cluster_id(conn, candidate.source_system, candidate.source_key)
            if cid is not None:
                matched_clusters.add(cid)

    # Get current cluster of the incoming record (if it already exists)
    current_cluster = get_cluster_id(conn, record.source_system, record.source_key)
    if current_cluster is not None:
        matched_clusters.add(current_cluster)

    if not matched_clusters:
        # No matches found -- create new cluster
        cluster_id = create_new_cluster(conn, record.source_system, record.source_key)
        return cluster_id, True

    # Assign record to one of the matched clusters
    cluster_list = sorted(matched_clusters)
    primary_cluster = cluster_list[0]

    # Assign the record to the primary cluster
    assign_to_cluster(conn, record.source_system, record.source_key, primary_cluster)

    # Merge all other matched clusters into the primary
    cluster_changed = current_cluster is None or current_cluster != primary_cluster
    for other_cluster in cluster_list[1:]:
        if other_cluster != primary_cluster:
            merge_clusters(conn, primary_cluster, other_cluster)
            cluster_changed = True

    return primary_cluster, cluster_changed
