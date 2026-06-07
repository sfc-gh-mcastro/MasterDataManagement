-- =============================================================================
-- 001_source_tables.sql -- Source customer and address tables with blocking indexes
-- =============================================================================

CREATE TABLE IF NOT EXISTS source_customers (
    source_system VARCHAR(5) NOT NULL,
    source_key VARCHAR(50) NOT NULL,
    first_name VARCHAR(200),
    last_name VARCHAR(200),
    canonical_first_name VARCHAR(200),
    email VARCHAR(255),
    phone VARCHAR(50),
    block_soundex VARCHAR(4),
    block_email_domain VARCHAR(255),
    block_phone_suffix VARCHAR(4),
    event_timestamp TIMESTAMPTZ NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source_system, source_key)
);

CREATE INDEX IF NOT EXISTS idx_block_soundex ON source_customers (block_soundex);
CREATE INDEX IF NOT EXISTS idx_block_email ON source_customers (block_email_domain);
CREATE INDEX IF NOT EXISTS idx_block_phone ON source_customers (block_phone_suffix);
CREATE INDEX IF NOT EXISTS idx_email_exact ON source_customers (email);

-- Source addresses (Phase 2 -- schema created now for forward compatibility)
CREATE TABLE IF NOT EXISTS source_addresses (
    source_system VARCHAR(5) NOT NULL,
    source_key VARCHAR(50) NOT NULL,
    source_customer_key VARCHAR(50) NOT NULL,
    street VARCHAR(255),
    city VARCHAR(100),
    postal_code VARCHAR(20),
    country VARCHAR(10),
    event_timestamp TIMESTAMPTZ NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source_system, source_key)
);
