-- =============================================================================
-- analytics.sql — Dynamic Table chain for Norwegian banking MDM pipeline
-- Sources: FREG (Folkeregisteret), BS (Bank System), NICE (CRM)
-- Organizations: BANK and INS — golden records partitioned "BY" (group, org)
-- Two isolated implementations: AI (Cortex-powered) and FUZZY (classical)
-- =============================================================================

-- =============================================================================
-- AI PIPELINE — Uses Cortex AI for Norwegian nickname resolution
-- =============================================================================

DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_ENRICHED_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Cortex AI enrichment: Norwegian nickname resolution, fake-name detection, SSN validation. Grain: (source_system, source_key, organization).'
AS
SELECT
    source_system,
    source_key,
    ssn,
    first_name,
    last_name,
    birth_date,
    citizenship,
    phone,
    email,
    record_date,
    organization,
    _source_file,
    -- Norwegian nickname → canonical form via Cortex (e.g. Per→Petter, Kari→Karen)
    CASE WHEN first_name IS NOT NULL AND LENGTH(TRIM(first_name)) > 1
        THEN INITCAP(TRIM(SNOWFLAKE.CORTEX.COMPLETE('mistral-large2',
            'Return ONLY the canonical/formal Norwegian given name. Just the name, nothing else. Name: ' || first_name)))
        ELSE first_name
    END AS canonical_first_name,
    -- Fake / test name detection
    CASE WHEN first_name IS NOT NULL AND last_name IS NOT NULL
             AND LENGTH(TRIM(first_name)) > 0 AND LENGTH(TRIM(last_name)) > 0
        THEN CAST(SNOWFLAKE.CORTEX.AI_CLASSIFY(TRIM(first_name) || ' ' || TRIM(last_name),
            ['real_person_name', 'fake_or_test_name']) AS VARIANT):label::VARCHAR = 'fake_or_test_name'
        ELSE FALSE
    END AS is_fake_name,
    -- SSN validation: 11-digit format + parseable DDMMYY birth date in first 6 digits
    CASE WHEN ssn IS NOT NULL
             AND REGEXP_LIKE(ssn, '^[0-9]{11}$')
             AND TRY_TO_DATE(SUBSTR(ssn, 1, 6), 'DDMMYY') IS NOT NULL
         THEN TRUE ELSE FALSE
    END AS ssn_valid,
    -- MDM processing timestamp (UTC)
    CONVERT_TIMEZONE('UTC', SYSDATE())::TIMESTAMP_NTZ AS mdm_processed_date
FROM {{db}}.{{agg_schema}}.CRMA_AGG_VW_CUSTOMER_UNION;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Entity resolution for Norwegian MDM. Blocking: SSN bucket OR SOUNDEX(last_name)+birth-year. Partitioned "BY" ORGANIZATION. Match rules: D01/D01b/D02/FUZZY. AI pipeline.'
AS
WITH base AS (
    SELECT DISTINCT
        source_system, source_key, ssn, first_name, last_name, birth_date,
        canonical_first_name, organization, phone, email,
        -- Blocking keys
        ssn                                         AS block_ssn,
        SOUNDEX(last_name)                          AS block_soundex,
        LEFT(birth_date::VARCHAR, 4)                AS block_birth_year
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_ENRICHED_AI
),
blocked_pairs AS (
    SELECT DISTINCT
        a.source_system AS source_a, a.source_key AS key_a,
        b.source_system AS source_b, b.source_key AS key_b,
        a.organization,
        a.ssn AS ssn_a, b.ssn AS ssn_b,
        a.canonical_first_name AS fn_a, a.last_name AS ln_a,
        b.canonical_first_name AS fn_b, b.last_name AS ln_b,
        a.phone AS phone_a, b.phone AS phone_b
    FROM base a JOIN base b
        ON  a.organization = b.organization    -- BANK↔BANK, INS↔INS only
        AND (   a.source_system < b.source_system
             OR (a.source_system = b.source_system AND a.source_key < b.source_key))
        AND (   -- SSN bucket
                (a.block_ssn IS NOT NULL AND b.block_ssn IS NOT NULL AND a.block_ssn = b.block_ssn)
                -- Name+birth-year bucket (fallback when SSN absent)
             OR (a.block_soundex IS NOT NULL AND a.block_soundex = b.block_soundex
                 AND a.block_birth_year IS NOT NULL AND a.block_birth_year = b.block_birth_year)
            )
),
match_pairs AS (
    SELECT source_a, key_a, source_b, key_b, organization,
        -- MATCH-D01: SSN exact + both names exact (composite primary) → 1.0
        CASE WHEN ssn_a IS NOT NULL AND ssn_a = ssn_b
                 AND LOWER(TRIM(COALESCE(fn_a, ''))) = LOWER(TRIM(COALESCE(fn_b, '')))
                 AND LOWER(TRIM(COALESCE(ln_a, ''))) = LOWER(TRIM(COALESCE(ln_b, '')))
             THEN 1.0 ELSE 0.0 END AS score_d01,
        -- MATCH-D01b: SSN exact, names differ slightly → 0.98
        CASE WHEN ssn_a IS NOT NULL AND ssn_a = ssn_b
                 AND NOT (LOWER(TRIM(COALESCE(fn_a, ''))) = LOWER(TRIM(COALESCE(fn_b, '')))
                          AND LOWER(TRIM(COALESCE(ln_a, ''))) = LOWER(TRIM(COALESCE(ln_b, ''))))
             THEN 0.98 ELSE 0.0 END AS score_d01b,
        -- MATCH-D02: phone last 8 digits normalized (Norwegian +47 XXXXXXXX) → 0.95
        CASE WHEN phone_a IS NOT NULL AND phone_b IS NOT NULL
                 AND LENGTH(REGEXP_REPLACE(phone_a, '[^0-9]', '')) >= 8
                 AND LENGTH(REGEXP_REPLACE(phone_b, '[^0-9]', '')) >= 8
                 AND RIGHT(REGEXP_REPLACE(phone_a, '[^0-9]', ''), 8)
                     = RIGHT(REGEXP_REPLACE(phone_b, '[^0-9]', ''), 8)
             THEN 0.95 ELSE 0.0 END AS score_d02,
        -- FUZZY: Jaro-Winkler full-name similarity ≥ 85 → scaled to 0.85
        CASE WHEN fn_a IS NOT NULL AND fn_b IS NOT NULL AND ln_a IS NOT NULL AND ln_b IS NOT NULL
                 AND JAROWINKLER_SIMILARITY(CONCAT(fn_a, ' ', ln_a), CONCAT(fn_b, ' ', ln_b)) >= 85
             THEN JAROWINKLER_SIMILARITY(CONCAT(fn_a, ' ', ln_a), CONCAT(fn_b, ' ', ln_b)) / 100.0 * 0.85
             ELSE 0.0 END AS score_fuzzy_name,
        -- SOUNDEX tiebreaker
        CASE WHEN SOUNDEX(ln_a) IS NOT NULL AND SOUNDEX(ln_a) = SOUNDEX(ln_b)
             THEN 0.10 ELSE 0.0 END AS score_soundex
    FROM blocked_pairs
),
scored_pairs AS (
    SELECT source_a, key_a, source_b, key_b, organization,
        GREATEST(score_d01, score_d01b, score_d02) + score_fuzzy_name + score_soundex AS total_score,
        CASE
            WHEN score_d01  >= 1.0  THEN 'D01'
            WHEN score_d01b >= 0.98 THEN 'D01b'
            WHEN score_d02  >= 0.95 THEN 'D02'
            WHEN score_fuzzy_name > 0.0 THEN 'FUZZY'
            ELSE 'OTHER'
        END AS match_type
    FROM match_pairs
),
matches AS (
    -- Apply threshold and exclude unmerge overrides (durable Scenario 5 split)
    SELECT source_a, key_a, source_b, key_b, organization, match_type, total_score
    FROM scored_pairs
    WHERE total_score >= 0.70
      AND NOT EXISTS (
          SELECT 1 FROM {{db}}.{{agg_schema}}.CRMA_AGG_TB_UNMERGE_OVERRIDES uo
          WHERE (uo.SOURCE_KEY_A = key_a AND uo.SOURCE_KEY_B = key_b)
             OR (uo.SOURCE_KEY_A = key_b AND uo.SOURCE_KEY_B = key_a)
      )
),
matched_clusters AS (
    -- Build clusters per organization; include SSN for STEWARD_QUEUE logic
    SELECT b.source_system, b.source_key, b.organization, b.ssn,
        COALESCE(
            MIN(b.organization || '|' || m.source_a || '|' || m.key_a),
            b.organization || '|' || b.source_system || '|' || b.source_key
        ) AS cluster_id,
        MAX(m.match_type)   AS match_type,
        MAX(m.total_score)  AS best_score
    FROM base b
    LEFT JOIN matches m ON b.organization = m.organization
        AND ((b.source_system = m.source_a AND b.source_key = m.key_a)
          OR (b.source_system = m.source_b AND b.source_key = m.key_b))
    GROUP BY b.source_system, b.source_key, b.organization, b.ssn
),
ranked AS (
    SELECT
        DENSE_RANK() OVER (PARTITION BY organization ORDER BY cluster_id) AS customer_group_id,
        source_system, source_key, organization, cluster_id, ssn,
        COALESCE(match_type, 'SINGLETON') AS match_type,
        best_score AS match_score
    FROM matched_clusters
)
SELECT
    customer_group_id, source_system, source_key, organization, cluster_id,
    match_type, match_score,
    -- STEWARD_QUEUE: singleton with no SSN → manual review required (Scenario 4)
    CASE WHEN match_type = 'SINGLETON' AND ssn IS NULL
         THEN 'STEWARD_QUEUE' ELSE 'MATCHED'
    END AS match_status
FROM ranked;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GOLDEN_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Golden customer records with org-partitioned survivorship and Norwegian DQ scoring. Key: (customer_group_id, organization). AI pipeline.'
AS
WITH grouped AS (
    SELECT
        g.customer_group_id, g.organization, g.source_system, g.source_key,
        e.ssn, e.first_name, e.last_name, e.birth_date, e.citizenship,
        e.phone, e.email, e.record_date, e.mdm_processed_date,
        e.ssn_valid, e.is_fake_name,
        -- Per-org source priority for most fields
        -- BANK: FREG=1, BS=2, NICE=3  |  INS: FREG=1, BS=2, NICE=2
        CASE
            WHEN g.organization = 'BANK' THEN
                CASE g.source_system WHEN 'FREG' THEN 1 WHEN 'BS' THEN 2 ELSE 3 END
            ELSE -- INS: BS and NICE tied
                CASE g.source_system WHEN 'FREG' THEN 1 WHEN 'BS' THEN 2 WHEN 'NICE' THEN 2 ELSE 3 END
        END AS source_priority,
        -- Citizenship: BANK → FREG=1, BS=1, NICE=2 (FREG and BS tied)  |  INS → FREG=1, rest=2
        CASE
            WHEN g.organization = 'BANK' THEN
                CASE g.source_system WHEN 'FREG' THEN 1 WHEN 'BS' THEN 1 ELSE 2 END
            ELSE -- INS
                CASE g.source_system WHEN 'FREG' THEN 1 ELSE 2 END
        END AS citizenship_priority
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_AI g
    JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_ENRICHED_AI e
        ON g.source_system = e.source_system
       AND g.source_key    = e.source_key
       AND g.organization  = e.organization
),
survivorship AS (
    SELECT customer_group_id, organization, record_date, mdm_processed_date,
        FIRST_VALUE(ssn) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN ssn IS NOT NULL THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS ssn,
        FIRST_VALUE(first_name) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN LENGTH(TRIM(COALESCE(first_name, ''))) > 1 THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS first_name,
        FIRST_VALUE(last_name) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN LENGTH(TRIM(COALESCE(last_name, ''))) > 1 THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS last_name,
        FIRST_VALUE(birth_date) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN birth_date IS NOT NULL THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS birth_date,
        -- Citizenship uses its own priority (BANK: FREG+BS tied; INS: FREG only)
        FIRST_VALUE(citizenship) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN citizenship IS NOT NULL THEN 0 ELSE 1 END,
                     citizenship_priority, record_date DESC, mdm_processed_date DESC
        ) AS citizenship,
        FIRST_VALUE(phone) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN phone IS NOT NULL AND LENGTH(REGEXP_REPLACE(phone, '[^0-9]', '')) >= 8 THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS phone,
        FIRST_VALUE(email) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN email LIKE '%@%' THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS email,
        COUNT(DISTINCT source_system) OVER (PARTITION BY customer_group_id, organization) AS source_count,
        MAX(CASE WHEN is_fake_name THEN 1 ELSE 0 END) OVER (PARTITION BY customer_group_id, organization) = 1 AS is_fake_name,
        MAX(CASE WHEN ssn_valid   THEN 1 ELSE 0 END) OVER (PARTITION BY customer_group_id, organization) = 1 AS ssn_valid
    FROM grouped
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY customer_group_id, organization
        ORDER BY source_priority, record_date DESC, mdm_processed_date DESC
    ) = 1
),
dq_rules AS (
    SELECT customer_group_id, organization, ssn, first_name, last_name,
           birth_date, citizenship, phone, email,
           record_date, mdm_processed_date, source_count, is_fake_name, ssn_valid,
        100
        -- Email rules
        + CASE WHEN email IS NULL OR NOT RLIKE(email, '^[A-Za-z0-9._%+\055]+@[A-Za-z0-9.\055]+\.[A-Za-z]{2,}$') THEN -20 ELSE 0 END
        + CASE WHEN email IS NOT NULL AND (LOWER(email) LIKE '%@mailinator.com' OR LOWER(email) LIKE '%@tempmail.com') THEN -5 ELSE 0 END
        -- Name rules (Norwegian characters æøåÆØÅ allowed)
        + CASE WHEN first_name IS NULL OR LENGTH(TRIM(first_name)) <= 1 THEN -20 ELSE 0 END
        + CASE WHEN first_name IS NOT NULL AND LENGTH(TRIM(first_name)) > 1
                   AND NOT RLIKE(first_name, '^[A-Za-zæøåÆØÅ \'\055]+$') THEN -5 ELSE 0 END
        + CASE WHEN last_name IS NULL OR LENGTH(TRIM(last_name)) <= 1 THEN -20 ELSE 0 END
        + CASE WHEN last_name IS NOT NULL AND LENGTH(TRIM(last_name)) > 1
                   AND NOT RLIKE(last_name, '^[A-Za-zæøåÆØÅ \'\055]+$') THEN -5 ELSE 0 END
        -- DQ-N01: Norwegian phone format (+47 + 8 digits)
        + CASE WHEN phone IS NOT NULL
                   AND NOT RLIKE(REGEXP_REPLACE(phone, '[^0-9+]', ''), '^\+47[0-9]{8}$') THEN -5 ELSE 0 END
        + CASE WHEN phone IS NOT NULL
                   AND REGEXP_REPLACE(phone, '[^0-9]', '') IN ('00000000000', '11111111111') THEN -20 ELSE 0 END
        -- DQ-N03: SSN 11-digit format + date validity
        + CASE WHEN ssn IS NOT NULL AND NOT ssn_valid THEN -20 ELSE 0 END
        -- Fake name penalty
        + CASE WHEN is_fake_name THEN -20 ELSE 0 END
        -- Bonus: first name appears in email prefix
        + CASE WHEN first_name IS NOT NULL AND LENGTH(TRIM(first_name)) > 1
                   AND email IS NOT NULL AND POSITION(LOWER(TRIM(first_name)) IN LOWER(email)) > 0 THEN 5 ELSE 0 END
        AS raw_dq_score
    FROM survivorship
)
SELECT
    customer_group_id, organization, ssn, first_name, last_name, birth_date, citizenship,
    phone, email, record_date, mdm_processed_date, source_count,
    GREATEST(0, LEAST(100, raw_dq_score)) AS dq_score
FROM dq_rules;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_STEWARD_QUEUE_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Records requiring manual data steward review: no SSN and no confident match. Scenario 4. AI pipeline.'
AS
SELECT
    g.source_key, g.source_system, g.organization,
    e.first_name, e.last_name, e.phone, e.email,
    e.record_date, e.mdm_processed_date
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_AI g
JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_ENRICHED_AI e
    ON g.source_system = e.source_system
   AND g.source_key    = e.source_key
   AND g.organization  = e.organization
WHERE g.match_status = 'STEWARD_QUEUE';


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Current golden customer records (latest version only). Key: (customer_group_id, organization). AI pipeline.'
AS
SELECT
    customer_group_id, organization, ssn, first_name, last_name,
    birth_date, citizenship, phone, email, dq_score, source_count,
    record_date AS last_updated, mdm_processed_date
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GOLDEN_AI
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY customer_group_id, organization
    ORDER BY record_date DESC, mdm_processed_date DESC
) = 1;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_HISTORY_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'SCD Type 2 customer history including Norwegian fields. AI pipeline.'
AS
WITH versioned AS (
    SELECT customer_group_id, organization, ssn, first_name, last_name,
           birth_date, citizenship, phone, email, dq_score, record_date, mdm_processed_date,
        SHA2(CONCAT(
            COALESCE(ssn,            ''), '|',
            COALESCE(first_name,     ''), '|',
            COALESCE(last_name,      ''), '|',
            COALESCE(birth_date::VARCHAR,    ''), '|',
            COALESCE(citizenship,    ''), '|',
            COALESCE(phone,          ''), '|',
            COALESCE(email,          ''), '|',
            COALESCE(dq_score::VARCHAR, '')
        )) AS row_hash,
        LAG(SHA2(CONCAT(
            COALESCE(ssn,            ''), '|',
            COALESCE(first_name,     ''), '|',
            COALESCE(last_name,      ''), '|',
            COALESCE(birth_date::VARCHAR,    ''), '|',
            COALESCE(citizenship,    ''), '|',
            COALESCE(phone,          ''), '|',
            COALESCE(email,          ''), '|',
            COALESCE(dq_score::VARCHAR, '')
        ))) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY record_date, mdm_processed_date
        ) AS prev_hash
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GOLDEN_AI
),
changes AS (SELECT * FROM versioned WHERE prev_hash IS NULL OR row_hash != prev_hash),
scd2 AS (
    SELECT customer_group_id, organization, ssn, first_name, last_name,
           birth_date, citizenship, phone, email, dq_score,
        mdm_processed_date AS valid_from,
        COALESCE(
            LEAD(mdm_processed_date) OVER (
                PARTITION BY customer_group_id, organization
                ORDER BY record_date, mdm_processed_date
            ),
            '9999-12-31'::TIMESTAMP_LTZ
        ) AS valid_to,
        row_hash
    FROM changes
)
SELECT
    customer_group_id, organization, ssn, first_name, last_name,
    birth_date, citizenship, phone, email, dq_score,
    valid_from, valid_to,
    CASE WHEN valid_to = '9999-12-31'::TIMESTAMP_LTZ THEN TRUE ELSE FALSE END AS is_valid,
    row_hash
FROM scd2;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GROUPS_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Links source addresses to master customer group records via SSN/customer key. AI pipeline.'
AS
WITH linked AS (
    SELECT DISTINCT
        a.source_system, a.source_key, a.source_customer_key, a.organization, g.customer_group_id
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_VW_ADDRESSES_UNION a
    JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_AI g
        ON  a.source_system         = g.source_system
        AND a.source_customer_key   = g.source_key
        AND a.organization          = g.organization
)
SELECT
    ROW_NUMBER() OVER (ORDER BY customer_group_id, organization, source_system, source_key) AS address_id,
    customer_group_id, source_system, source_key, organization,
    customer_group_id::VARCHAR AS cluster_id
FROM linked;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GOLDEN_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Golden Norwegian address per customer-org with survivorship and DQ scoring. AI pipeline.'
AS
WITH grouped AS (
    SELECT
        g.address_id, g.customer_group_id, g.organization, g.source_system, g.source_key,
        u.gate, u.postnummer, u."BY", u.land, u.row_timestamp,
        CASE g.source_system WHEN 'FREG' THEN 1 WHEN 'BS' THEN 2 ELSE 3 END AS source_priority
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GROUPS_AI g
    JOIN {{db}}.{{agg_schema}}.CRMA_AGG_VW_ADDRESSES_UNION u
        ON g.source_system = u.source_system AND g.source_key = u.source_key AND g.organization = u.organization
),
survivorship AS (
    SELECT customer_group_id, organization, row_timestamp,
        FIRST_VALUE(gate) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN LENGTH(TRIM(COALESCE(gate, ''))) >= 3 THEN 0 ELSE 1 END,
                     source_priority, row_timestamp DESC
        ) AS gate,
        FIRST_VALUE(postnummer) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN postnummer IS NOT NULL THEN 0 ELSE 1 END,
                     source_priority, row_timestamp DESC
        ) AS postnummer,
        FIRST_VALUE("BY") OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN "BY" IS NOT NULL THEN 0 ELSE 1 END,
                     source_priority, row_timestamp DESC
        ) AS "BY",
        FIRST_VALUE(land) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN land IS NOT NULL THEN source_priority ELSE 99 END,
                     row_timestamp DESC
        ) AS land
    FROM grouped
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY customer_group_id, organization ORDER BY source_priority
    ) = 1
),
dq_rules AS (
    SELECT customer_group_id, organization, gate, postnummer, "BY", land, row_timestamp,
        100
        + CASE WHEN gate IS NULL OR LENGTH(TRIM(gate)) < 3 THEN -5 ELSE 0 END
        + CASE WHEN "BY" IS NULL THEN -20 ELSE 0 END
        + CASE WHEN gate IS NOT NULL AND LENGTH(TRIM(gate)) >= 3
                   AND postnummer IS NOT NULL AND "BY" IS NOT NULL THEN 10 ELSE 0 END
        -- DQ-N02: Norwegian postnummer must be exactly 4 digits
        + CASE WHEN postnummer IS NOT NULL AND NOT RLIKE(postnummer, '^[0-9]{4}$') THEN -5 ELSE 0 END
        AS raw_dq_score
    FROM survivorship
)
SELECT
    customer_group_id, organization, 'PRIMARY' AS address_type,
    gate, postnummer, "BY", land, TRUE AS is_primary, row_timestamp,
    GREATEST(0, LEAST(100, raw_dq_score)) AS dq_score
FROM dq_rules;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Current golden Norwegian address per customer-org (latest version only). AI pipeline.'
AS
SELECT customer_group_id, organization, address_type, gate, postnummer, "BY", land, is_primary, dq_score
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GOLDEN_AI
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_group_id, organization ORDER BY row_timestamp DESC) = 1;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_HISTORY_AI
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'SCD Type 2 Norwegian address history. AI pipeline.'
AS
WITH versioned AS (
    SELECT customer_group_id, organization, address_type, gate, postnummer, "BY", land, is_primary, dq_score, row_timestamp,
        SHA2(CONCAT(
            COALESCE(address_type, ''), '|', COALESCE(gate, ''),       '|',
            COALESCE(postnummer,   ''), '|', COALESCE(by, ''),         '|',
            COALESCE(land,         ''), '|', COALESCE(is_primary::VARCHAR, ''), '|',
            COALESCE(dq_score::VARCHAR, '')
        )) AS row_hash,
        LAG(SHA2(CONCAT(
            COALESCE(address_type, ''), '|', COALESCE(gate, ''),       '|',
            COALESCE(postnummer,   ''), '|', COALESCE(by, ''),         '|',
            COALESCE(land,         ''), '|', COALESCE(is_primary::VARCHAR, ''), '|',
            COALESCE(dq_score::VARCHAR, '')
        ))) OVER (PARTITION BY customer_group_id, organization ORDER BY row_timestamp) AS prev_hash
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GOLDEN_AI
),
changes AS (SELECT * FROM versioned WHERE prev_hash IS NULL OR row_hash != prev_hash),
scd2 AS (
    SELECT customer_group_id, organization, address_type, gate, postnummer, "BY", land, is_primary, dq_score,
        row_timestamp AS valid_from,
        COALESCE(
            LEAD(row_timestamp) OVER (PARTITION BY customer_group_id, organization ORDER BY row_timestamp),
            '9999-12-31'::TIMESTAMP_LTZ
        ) AS valid_to,
        row_hash
    FROM changes
)
SELECT customer_group_id, organization, address_type, gate, postnummer, "BY", land, is_primary, dq_score,
    valid_from, valid_to,
    CASE WHEN valid_to = '9999-12-31'::TIMESTAMP_LTZ THEN TRUE ELSE FALSE END AS is_valid,
    row_hash
FROM scd2;


-- =============================================================================
-- FUZZY PIPELINE — Classical matching only (no Cortex AI, zero AI cost)
-- =============================================================================

DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_ENRICHED_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Classical enrichment (no Cortex AI). INITCAP as canonical name, is_fake_name always FALSE.'
AS
SELECT
    source_system,
    source_key,
    ssn,
    first_name,
    last_name,
    birth_date,
    citizenship,
    phone,
    email,
    record_date,
    organization,
    _source_file,
    INITCAP(TRIM(first_name)) AS canonical_first_name,
    FALSE                     AS is_fake_name,
    -- SSN validation: 11-digit format + parseable DDMMYY birth date
    CASE WHEN ssn IS NOT NULL
             AND REGEXP_LIKE(ssn, '^[0-9]{11}$')
             AND TRY_TO_DATE(SUBSTR(ssn, 1, 6), 'DDMMYY') IS NOT NULL
         THEN TRUE ELSE FALSE
    END AS ssn_valid,
    CONVERT_TIMEZONE('UTC', SYSDATE())::TIMESTAMP_NTZ AS mdm_processed_date
FROM {{db}}.{{agg_schema}}.CRMA_AGG_VW_CUSTOMER_UNION;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Entity resolution for Norwegian MDM. Blocking: SSN bucket OR SOUNDEX(last_name)+birth-year. Partitioned "BY" ORGANIZATION. Match rules: D01/D01b/D02/FUZZY. Fuzzy pipeline.'
AS
WITH base AS (
    SELECT DISTINCT
        source_system, source_key, ssn, first_name, last_name, birth_date,
        canonical_first_name, organization, phone, email,
        ssn                             AS block_ssn,
        SOUNDEX(last_name)              AS block_soundex,
        LEFT(birth_date::VARCHAR, 4)    AS block_birth_year
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_ENRICHED_FUZZY
),
blocked_pairs AS (
    SELECT DISTINCT
        a.source_system AS source_a, a.source_key AS key_a,
        b.source_system AS source_b, b.source_key AS key_b,
        a.organization,
        a.ssn AS ssn_a, b.ssn AS ssn_b,
        a.canonical_first_name AS fn_a, a.last_name AS ln_a,
        b.canonical_first_name AS fn_b, b.last_name AS ln_b,
        a.phone AS phone_a, b.phone AS phone_b
    FROM base a JOIN base b
        ON  a.organization = b.organization
        AND (   a.source_system < b.source_system
             OR (a.source_system = b.source_system AND a.source_key < b.source_key))
        AND (   (a.block_ssn IS NOT NULL AND b.block_ssn IS NOT NULL AND a.block_ssn = b.block_ssn)
             OR (a.block_soundex IS NOT NULL AND a.block_soundex = b.block_soundex
                 AND a.block_birth_year IS NOT NULL AND a.block_birth_year = b.block_birth_year)
            )
),
match_pairs AS (
    SELECT source_a, key_a, source_b, key_b, organization,
        CASE WHEN ssn_a IS NOT NULL AND ssn_a = ssn_b
                 AND LOWER(TRIM(COALESCE(fn_a, ''))) = LOWER(TRIM(COALESCE(fn_b, '')))
                 AND LOWER(TRIM(COALESCE(ln_a, ''))) = LOWER(TRIM(COALESCE(ln_b, '')))
             THEN 1.0 ELSE 0.0 END AS score_d01,
        CASE WHEN ssn_a IS NOT NULL AND ssn_a = ssn_b
                 AND NOT (LOWER(TRIM(COALESCE(fn_a, ''))) = LOWER(TRIM(COALESCE(fn_b, '')))
                          AND LOWER(TRIM(COALESCE(ln_a, ''))) = LOWER(TRIM(COALESCE(ln_b, ''))))
             THEN 0.98 ELSE 0.0 END AS score_d01b,
        CASE WHEN phone_a IS NOT NULL AND phone_b IS NOT NULL
                 AND LENGTH(REGEXP_REPLACE(phone_a, '[^0-9]', '')) >= 8
                 AND LENGTH(REGEXP_REPLACE(phone_b, '[^0-9]', '')) >= 8
                 AND RIGHT(REGEXP_REPLACE(phone_a, '[^0-9]', ''), 8)
                     = RIGHT(REGEXP_REPLACE(phone_b, '[^0-9]', ''), 8)
             THEN 0.95 ELSE 0.0 END AS score_d02,
        CASE WHEN fn_a IS NOT NULL AND fn_b IS NOT NULL AND ln_a IS NOT NULL AND ln_b IS NOT NULL
                 AND JAROWINKLER_SIMILARITY(CONCAT(fn_a, ' ', ln_a), CONCAT(fn_b, ' ', ln_b)) >= 85
             THEN JAROWINKLER_SIMILARITY(CONCAT(fn_a, ' ', ln_a), CONCAT(fn_b, ' ', ln_b)) / 100.0 * 0.85
             ELSE 0.0 END AS score_fuzzy_name,
        CASE WHEN SOUNDEX(ln_a) IS NOT NULL AND SOUNDEX(ln_a) = SOUNDEX(ln_b)
             THEN 0.10 ELSE 0.0 END AS score_soundex
    FROM blocked_pairs
),
scored_pairs AS (
    SELECT source_a, key_a, source_b, key_b, organization,
        GREATEST(score_d01, score_d01b, score_d02) + score_fuzzy_name + score_soundex AS total_score,
        CASE
            WHEN score_d01  >= 1.0  THEN 'D01'
            WHEN score_d01b >= 0.98 THEN 'D01b'
            WHEN score_d02  >= 0.95 THEN 'D02'
            WHEN score_fuzzy_name > 0.0 THEN 'FUZZY'
            ELSE 'OTHER'
        END AS match_type
    FROM match_pairs
),
matches AS (
    SELECT source_a, key_a, source_b, key_b, organization, match_type, total_score
    FROM scored_pairs
    WHERE total_score >= 0.70
      AND NOT EXISTS (
          SELECT 1 FROM {{db}}.{{agg_schema}}.CRMA_AGG_TB_UNMERGE_OVERRIDES uo
          WHERE (uo.SOURCE_KEY_A = key_a AND uo.SOURCE_KEY_B = key_b)
             OR (uo.SOURCE_KEY_A = key_b AND uo.SOURCE_KEY_B = key_a)
      )
),
matched_clusters AS (
    SELECT b.source_system, b.source_key, b.organization, b.ssn,
        COALESCE(
            MIN(b.organization || '|' || m.source_a || '|' || m.key_a),
            b.organization || '|' || b.source_system || '|' || b.source_key
        ) AS cluster_id,
        MAX(m.match_type)  AS match_type,
        MAX(m.total_score) AS best_score
    FROM base b
    LEFT JOIN matches m ON b.organization = m.organization
        AND ((b.source_system = m.source_a AND b.source_key = m.key_a)
          OR (b.source_system = m.source_b AND b.source_key = m.key_b))
    GROUP BY b.source_system, b.source_key, b.organization, b.ssn
),
ranked AS (
    SELECT
        DENSE_RANK() OVER (PARTITION BY organization ORDER BY cluster_id) AS customer_group_id,
        source_system, source_key, organization, cluster_id, ssn,
        COALESCE(match_type, 'SINGLETON') AS match_type,
        best_score AS match_score
    FROM matched_clusters
)
SELECT
    customer_group_id, source_system, source_key, organization, cluster_id,
    match_type, match_score,
    CASE WHEN match_type = 'SINGLETON' AND ssn IS NULL
         THEN 'STEWARD_QUEUE' ELSE 'MATCHED'
    END AS match_status
FROM ranked;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GOLDEN_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Golden customer records with org-partitioned survivorship and Norwegian DQ scoring. Key: (customer_group_id, organization). Fuzzy pipeline.'
AS
WITH grouped AS (
    SELECT
        g.customer_group_id, g.organization, g.source_system, g.source_key,
        e.ssn, e.first_name, e.last_name, e.birth_date, e.citizenship,
        e.phone, e.email, e.record_date, e.mdm_processed_date,
        e.ssn_valid, e.is_fake_name,
        CASE
            WHEN g.organization = 'BANK' THEN
                CASE g.source_system WHEN 'FREG' THEN 1 WHEN 'BS' THEN 2 ELSE 3 END
            ELSE
                CASE g.source_system WHEN 'FREG' THEN 1 WHEN 'BS' THEN 2 WHEN 'NICE' THEN 2 ELSE 3 END
        END AS source_priority,
        CASE
            WHEN g.organization = 'BANK' THEN
                CASE g.source_system WHEN 'FREG' THEN 1 WHEN 'BS' THEN 1 ELSE 2 END
            ELSE
                CASE g.source_system WHEN 'FREG' THEN 1 ELSE 2 END
        END AS citizenship_priority
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_FUZZY g
    JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_ENRICHED_FUZZY e
        ON g.source_system = e.source_system
       AND g.source_key    = e.source_key
       AND g.organization  = e.organization
),
survivorship AS (
    SELECT customer_group_id, organization, record_date, mdm_processed_date,
        FIRST_VALUE(ssn) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN ssn IS NOT NULL THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS ssn,
        FIRST_VALUE(first_name) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN LENGTH(TRIM(COALESCE(first_name, ''))) > 1 THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS first_name,
        FIRST_VALUE(last_name) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN LENGTH(TRIM(COALESCE(last_name, ''))) > 1 THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS last_name,
        FIRST_VALUE(birth_date) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN birth_date IS NOT NULL THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS birth_date,
        FIRST_VALUE(citizenship) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN citizenship IS NOT NULL THEN 0 ELSE 1 END,
                     citizenship_priority, record_date DESC, mdm_processed_date DESC
        ) AS citizenship,
        FIRST_VALUE(phone) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN phone IS NOT NULL AND LENGTH(REGEXP_REPLACE(phone, '[^0-9]', '')) >= 8 THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS phone,
        FIRST_VALUE(email) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN email LIKE '%@%' THEN 0 ELSE 1 END,
                     source_priority, record_date DESC, mdm_processed_date DESC
        ) AS email,
        COUNT(DISTINCT source_system) OVER (PARTITION BY customer_group_id, organization) AS source_count,
        MAX(CASE WHEN is_fake_name THEN 1 ELSE 0 END) OVER (PARTITION BY customer_group_id, organization) = 1 AS is_fake_name,
        MAX(CASE WHEN ssn_valid   THEN 1 ELSE 0 END) OVER (PARTITION BY customer_group_id, organization) = 1 AS ssn_valid
    FROM grouped
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY customer_group_id, organization
        ORDER BY source_priority, record_date DESC, mdm_processed_date DESC
    ) = 1
),
dq_rules AS (
    SELECT customer_group_id, organization, ssn, first_name, last_name,
           birth_date, citizenship, phone, email,
           record_date, mdm_processed_date, source_count, is_fake_name, ssn_valid,
        100
        + CASE WHEN email IS NULL OR NOT RLIKE(email, '^[A-Za-z0-9._%+\055]+@[A-Za-z0-9.\055]+\.[A-Za-z]{2,}$') THEN -20 ELSE 0 END
        + CASE WHEN email IS NOT NULL AND (LOWER(email) LIKE '%@mailinator.com' OR LOWER(email) LIKE '%@tempmail.com') THEN -5 ELSE 0 END
        + CASE WHEN first_name IS NULL OR LENGTH(TRIM(first_name)) <= 1 THEN -20 ELSE 0 END
        + CASE WHEN first_name IS NOT NULL AND LENGTH(TRIM(first_name)) > 1
                   AND NOT RLIKE(first_name, '^[A-Za-zæøåÆØÅ \'\055]+$') THEN -5 ELSE 0 END
        + CASE WHEN last_name IS NULL OR LENGTH(TRIM(last_name)) <= 1 THEN -20 ELSE 0 END
        + CASE WHEN last_name IS NOT NULL AND LENGTH(TRIM(last_name)) > 1
                   AND NOT RLIKE(last_name, '^[A-Za-zæøåÆØÅ \'\055]+$') THEN -5 ELSE 0 END
        + CASE WHEN phone IS NOT NULL
                   AND NOT RLIKE(REGEXP_REPLACE(phone, '[^0-9+]', ''), '^\+47[0-9]{8}$') THEN -5 ELSE 0 END
        + CASE WHEN phone IS NOT NULL
                   AND REGEXP_REPLACE(phone, '[^0-9]', '') IN ('00000000000', '11111111111') THEN -20 ELSE 0 END
        + CASE WHEN ssn IS NOT NULL AND NOT ssn_valid THEN -20 ELSE 0 END
        + CASE WHEN is_fake_name THEN -20 ELSE 0 END
        + CASE WHEN first_name IS NOT NULL AND LENGTH(TRIM(first_name)) > 1
                   AND email IS NOT NULL AND POSITION(LOWER(TRIM(first_name)) IN LOWER(email)) > 0 THEN 5 ELSE 0 END
        AS raw_dq_score
    FROM survivorship
)
SELECT
    customer_group_id, organization, ssn, first_name, last_name, birth_date, citizenship,
    phone, email, record_date, mdm_processed_date, source_count,
    GREATEST(0, LEAST(100, raw_dq_score)) AS dq_score
FROM dq_rules;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_STEWARD_QUEUE_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Records requiring manual data steward review: no SSN and no confident match. Scenario 4. Fuzzy pipeline.'
AS
SELECT
    g.source_key, g.source_system, g.organization,
    e.first_name, e.last_name, e.phone, e.email,
    e.record_date, e.mdm_processed_date
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_FUZZY g
JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_ENRICHED_FUZZY e
    ON g.source_system = e.source_system
   AND g.source_key    = e.source_key
   AND g.organization  = e.organization
WHERE g.match_status = 'STEWARD_QUEUE';


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Current golden customer records (latest version only). Key: (customer_group_id, organization). Fuzzy pipeline.'
AS
SELECT
    customer_group_id, organization, ssn, first_name, last_name,
    birth_date, citizenship, phone, email, dq_score, source_count,
    record_date AS last_updated, mdm_processed_date
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GOLDEN_FUZZY
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY customer_group_id, organization
    ORDER BY record_date DESC, mdm_processed_date DESC
) = 1;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_HISTORY_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'SCD Type 2 customer history including Norwegian fields. Fuzzy pipeline.'
AS
WITH versioned AS (
    SELECT customer_group_id, organization, ssn, first_name, last_name,
           birth_date, citizenship, phone, email, dq_score, record_date, mdm_processed_date,
        SHA2(CONCAT(
            COALESCE(ssn,            ''), '|',
            COALESCE(first_name,     ''), '|',
            COALESCE(last_name,      ''), '|',
            COALESCE(birth_date::VARCHAR,    ''), '|',
            COALESCE(citizenship,    ''), '|',
            COALESCE(phone,          ''), '|',
            COALESCE(email,          ''), '|',
            COALESCE(dq_score::VARCHAR, '')
        )) AS row_hash,
        LAG(SHA2(CONCAT(
            COALESCE(ssn,            ''), '|',
            COALESCE(first_name,     ''), '|',
            COALESCE(last_name,      ''), '|',
            COALESCE(birth_date::VARCHAR,    ''), '|',
            COALESCE(citizenship,    ''), '|',
            COALESCE(phone,          ''), '|',
            COALESCE(email,          ''), '|',
            COALESCE(dq_score::VARCHAR, '')
        ))) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY record_date, mdm_processed_date
        ) AS prev_hash
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GOLDEN_FUZZY
),
changes AS (SELECT * FROM versioned WHERE prev_hash IS NULL OR row_hash != prev_hash),
scd2 AS (
    SELECT customer_group_id, organization, ssn, first_name, last_name,
           birth_date, citizenship, phone, email, dq_score,
        mdm_processed_date AS valid_from,
        COALESCE(
            LEAD(mdm_processed_date) OVER (
                PARTITION BY customer_group_id, organization
                ORDER BY record_date, mdm_processed_date
            ),
            '9999-12-31'::TIMESTAMP_LTZ
        ) AS valid_to,
        row_hash
    FROM changes
)
SELECT
    customer_group_id, organization, ssn, first_name, last_name,
    birth_date, citizenship, phone, email, dq_score,
    valid_from, valid_to,
    CASE WHEN valid_to = '9999-12-31'::TIMESTAMP_LTZ THEN TRUE ELSE FALSE END AS is_valid,
    row_hash
FROM scd2;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GROUPS_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Links source addresses to master customer group records via SSN/customer key. Fuzzy pipeline.'
AS
WITH linked AS (
    SELECT DISTINCT
        a.source_system, a.source_key, a.source_customer_key, a.organization, g.customer_group_id
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_VW_ADDRESSES_UNION a
    JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_FUZZY g
        ON  a.source_system       = g.source_system
        AND a.source_customer_key = g.source_key
        AND a.organization        = g.organization
)
SELECT
    ROW_NUMBER() OVER (ORDER BY customer_group_id, organization, source_system, source_key) AS address_id,
    customer_group_id, source_system, source_key, organization,
    customer_group_id::VARCHAR AS cluster_id
FROM linked;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GOLDEN_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Golden Norwegian address per customer-org with survivorship and DQ scoring. Fuzzy pipeline.'
AS
WITH grouped AS (
    SELECT
        g.address_id, g.customer_group_id, g.organization, g.source_system, g.source_key,
        u.gate, u.postnummer, u."BY", u.land, u.row_timestamp,
        CASE g.source_system WHEN 'FREG' THEN 1 WHEN 'BS' THEN 2 ELSE 3 END AS source_priority
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GROUPS_FUZZY g
    JOIN {{db}}.{{agg_schema}}.CRMA_AGG_VW_ADDRESSES_UNION u
        ON g.source_system = u.source_system AND g.source_key = u.source_key AND g.organization = u.organization
),
survivorship AS (
    SELECT customer_group_id, organization, row_timestamp,
        FIRST_VALUE(gate) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN LENGTH(TRIM(COALESCE(gate, ''))) >= 3 THEN 0 ELSE 1 END,
                     source_priority, row_timestamp DESC
        ) AS gate,
        FIRST_VALUE(postnummer) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN postnummer IS NOT NULL THEN 0 ELSE 1 END,
                     source_priority, row_timestamp DESC
        ) AS postnummer,
        FIRST_VALUE("BY") OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN "BY" IS NOT NULL THEN 0 ELSE 1 END,
                     source_priority, row_timestamp DESC
        ) AS "BY",
        FIRST_VALUE(land) OVER (
            PARTITION BY customer_group_id, organization
            ORDER BY CASE WHEN land IS NOT NULL THEN source_priority ELSE 99 END,
                     row_timestamp DESC
        ) AS land
    FROM grouped
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_group_id, organization ORDER BY source_priority) = 1
),
dq_rules AS (
    SELECT customer_group_id, organization, gate, postnummer, "BY", land, row_timestamp,
        100
        + CASE WHEN gate IS NULL OR LENGTH(TRIM(gate)) < 3 THEN -5 ELSE 0 END
        + CASE WHEN "BY" IS NULL THEN -20 ELSE 0 END
        + CASE WHEN gate IS NOT NULL AND LENGTH(TRIM(gate)) >= 3
                   AND postnummer IS NOT NULL AND "BY" IS NOT NULL THEN 10 ELSE 0 END
        + CASE WHEN postnummer IS NOT NULL AND NOT RLIKE(postnummer, '^[0-9]{4}$') THEN -5 ELSE 0 END
        AS raw_dq_score
    FROM survivorship
)
SELECT
    customer_group_id, organization, 'PRIMARY' AS address_type,
    gate, postnummer, "BY", land, TRUE AS is_primary, row_timestamp,
    GREATEST(0, LEAST(100, raw_dq_score)) AS dq_score
FROM dq_rules;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'Current golden Norwegian address per customer-org (latest version only). Fuzzy pipeline.'
AS
SELECT customer_group_id, organization, address_type, gate, postnummer, "BY", land, is_primary, dq_score
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GOLDEN_FUZZY
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_group_id, organization ORDER BY row_timestamp DESC) = 1;


DEFINE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_HISTORY_FUZZY
    WAREHOUSE = {{warehouse}}
    TARGET_LAG = '{{dt_lag}}'
    REFRESH_MODE = FULL
    COMMENT = 'SCD Type 2 Norwegian address history. Fuzzy pipeline.'
AS
WITH versioned AS (
    SELECT customer_group_id, organization, address_type, gate, postnummer, "BY", land, is_primary, dq_score, row_timestamp,
        SHA2(CONCAT(
            COALESCE(address_type, ''), '|', COALESCE(gate, ''),       '|',
            COALESCE(postnummer,   ''), '|', COALESCE(by, ''),         '|',
            COALESCE(land,         ''), '|', COALESCE(is_primary::VARCHAR, ''), '|',
            COALESCE(dq_score::VARCHAR, '')
        )) AS row_hash,
        LAG(SHA2(CONCAT(
            COALESCE(address_type, ''), '|', COALESCE(gate, ''),       '|',
            COALESCE(postnummer,   ''), '|', COALESCE(by, ''),         '|',
            COALESCE(land,         ''), '|', COALESCE(is_primary::VARCHAR, ''), '|',
            COALESCE(dq_score::VARCHAR, '')
        ))) OVER (PARTITION BY customer_group_id, organization ORDER BY row_timestamp) AS prev_hash
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GOLDEN_FUZZY
),
changes AS (SELECT * FROM versioned WHERE prev_hash IS NULL OR row_hash != prev_hash),
scd2 AS (
    SELECT customer_group_id, organization, address_type, gate, postnummer, "BY", land, is_primary, dq_score,
        row_timestamp AS valid_from,
        COALESCE(
            LEAD(row_timestamp) OVER (PARTITION BY customer_group_id, organization ORDER BY row_timestamp),
            '9999-12-31'::TIMESTAMP_LTZ
        ) AS valid_to,
        row_hash
    FROM changes
)
SELECT customer_group_id, organization, address_type, gate, postnummer, "BY", land, is_primary, dq_score,
    valid_from, valid_to,
    CASE WHEN valid_to = '9999-12-31'::TIMESTAMP_LTZ THEN TRUE ELSE FALSE END AS is_valid,
    row_hash
FROM scd2;
