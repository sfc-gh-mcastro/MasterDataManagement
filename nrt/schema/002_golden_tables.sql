-- =============================================================================
-- 002_golden_tables.sql -- Cluster, golden record (SCD2), and XREF tables
-- =============================================================================

CREATE SEQUENCE IF NOT EXISTS cluster_seq;

CREATE TABLE IF NOT EXISTS customer_clusters (
    source_system VARCHAR(5) NOT NULL,
    source_key VARCHAR(50) NOT NULL,
    cluster_id BIGINT NOT NULL,
    PRIMARY KEY (source_system, source_key)
);

CREATE INDEX IF NOT EXISTS idx_cluster_id ON customer_clusters (cluster_id);

CREATE TABLE IF NOT EXISTS golden_customers (
    id BIGSERIAL PRIMARY KEY,
    cluster_id BIGINT NOT NULL,
    first_name VARCHAR(200),
    last_name VARCHAR(200),
    email VARCHAR(255),
    phone VARCHAR(50),
    dq_score SMALLINT,
    source_count SMALLINT,
    row_hash VARCHAR(128),
    valid_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    valid_to TIMESTAMPTZ NOT NULL DEFAULT '9999-12-31',
    is_current BOOLEAN NOT NULL DEFAULT TRUE
);

-- Enforces exactly one current golden record per cluster
CREATE UNIQUE INDEX IF NOT EXISTS uq_golden_current_cluster
    ON golden_customers (cluster_id) WHERE is_current = TRUE;

CREATE TABLE IF NOT EXISTS customer_xref (
    source_system VARCHAR(5) NOT NULL,
    source_key VARCHAR(50) NOT NULL,
    customer_id BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source_system, source_key)
);

CREATE INDEX IF NOT EXISTS idx_xref_customer ON customer_xref (customer_id);

-- Note: No explicit foreign keys between tables. This is intentional:
-- FKs add write latency (constraint checks) on every UPSERT in the hot path.
-- Referential integrity is guaranteed by application logic (single transaction
-- encompasses cluster update + XREF update + golden write).
