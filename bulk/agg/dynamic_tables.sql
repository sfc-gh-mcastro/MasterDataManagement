-- =============================================================================
-- dynamic_tables.sql — Customer MDM golden record pipeline
-- Target schema : {{db}}.{{agg_schema}}  (MDM_DEV.MDM_AGG_v001)
-- Source schema : {{db}}.MDM_RAW_v001
-- Warehouse     : {{warehouse}}           (MD_TEST_WH)
-- Refresh mode  : FULL (all layers)
-- Target lag    : {{dt_lag}}              (intermediate layers: DOWNSTREAM)
--
-- Pipeline layers (dependency order):
--   1. CRMI_AGG_DT_ENRICHED      — union + SSN modulus-11 + nickname canon
--   2. CRMI_AGG_DT_GROUPS        — SSN exact match + JW fuzzy + steward flag
--   3. CRMI_AGG_DT_GOLDEN        — org-partitioned survivorship (FREG>BS>NICE)
--   4. CRMI_AGG_DT_CURRENT       — one row per (customer, org), row hash
--   5. CRMI_AGG_DT_HISTORY       — SCD Type 2, SHA2 change detection
--   6. CRMI_AGG_DT_STEWARD_QUEUE — unresolved records for manual review
--
-- Intermediate DTs (1-3) use TARGET_LAG = DOWNSTREAM so the chain refreshes
-- as a coordinated group driven by the three terminal DTs (4-6).
-- =============================================================================


-- =============================================================================
-- 1. CRMI_AGG_DT_ENRICHED
--    Normalises the three source tables to a common schema, validates each
--    Norwegian personnummer with the modulus-11 checksum, and resolves common
--    Norwegian nickname pairs to a canonical first name used in fuzzy matching.
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMI_AGG_DT_ENRICHED
    TARGET_LAG   = DOWNSTREAM
    WAREHOUSE    = {{warehouse}}
    REFRESH_MODE = FULL
    COMMENT      = 'Layer 1 – Enriched: common schema, SSN mod-11 validation, Norwegian nickname canonicalisation. Union of FREG (trust 3), BS (trust 2), NICE (trust 1).'
AS
WITH

-- ---------------------------------------------------------------------------
-- Norwegian nickname → canonical first name mapping (inline VALUES table).
-- Each variant maps to the most common written form used as the join key
-- during fuzzy matching.  Add/remove pairs here as the dataset grows.
-- ---------------------------------------------------------------------------
nicknames (nickname, canonical) AS (
    SELECT v.* FROM (VALUES
        ('PER',        'PER'),
        ('PETTER',     'PER'),
        ('PETER',      'PER'),
        ('OLE',        'OLE'),
        ('OLAV',       'OLE'),
        ('OLUF',       'OLE'),
        ('BJØRN',      'BJØRN'),
        ('BJÖRN',      'BJØRN'),
        ('KARI',       'KARI'),
        ('KARIN',      'KARI'),
        ('KAREN',      'KARI'),
        ('KATRINE',    'KARI'),
        ('MARIE',      'MARIE'),
        ('MARIA',      'MARIE'),
        ('MARI',       'MARIE'),
        ('MARIANNE',   'MARIE'),
        ('JON',        'JON'),
        ('JONAS',      'JON'),
        ('JONATHAN',   'JON'),
        ('ANN',        'ANN'),
        ('ANNE',       'ANN'),
        ('ANNA',       'ANN'),
        ('ANNIKEN',    'ANN'),
        ('ANETTE',     'ANN'),
        ('LARS',       'LARS'),
        ('LAURITZ',    'LARS'),
        ('LAURITS',    'LARS'),
        ('LISE',       'LISE'),
        ('LISA',       'LISE'),
        ('ELISABETH',  'LISE'),
        ('EIRIK',      'EIRIK'),
        ('ERIK',       'EIRIK'),
        ('TRINE',      'TRINE'),
        ('HILDE',      'HILDE'),
        ('HILDEGUNN',  'HILDE')
    ) AS v (nickname, canonical)
),

-- ---------------------------------------------------------------------------
-- Cast each source to the 12-column common schema.
-- FREG: no phone/email/organization  →  typed NULLs
-- BS/NICE: no birth_date/citizenship →  typed NULLs
-- ---------------------------------------------------------------------------
raw_freg AS (
    SELECT
        SSN,
        FIRST_NAME,
        LAST_NAME,
        BIRTH_DATE,
        CITIZENSHIP,
        NULL::VARCHAR(20)   AS PHONE,
        NULL::VARCHAR(255)  AS EMAIL,
        NULL::VARCHAR(10)   AS ORGANIZATION,
        RECORD_DATE,
        'FREG'              AS SOURCE_SYSTEM,
        3                   AS TRUST_SCORE,
        _SOURCE_FILE
    FROM {{db}}.MDM_RAW_v001.CRMI_RAW_TB_FREG
),

raw_bs AS (
    SELECT
        SSN,
        FIRST_NAME,
        LAST_NAME,
        NULL::DATE          AS BIRTH_DATE,
        NULL::VARCHAR(5)    AS CITIZENSHIP,
        PHONE,
        EMAIL,
        ORGANIZATION,
        RECORD_DATE,
        'BS'                AS SOURCE_SYSTEM,
        2                   AS TRUST_SCORE,
        _SOURCE_FILE
    FROM {{db}}.MDM_RAW_v001.CRMI_RAW_TB_BS
),

raw_nice AS (
    SELECT
        SSN,
        FIRST_NAME,
        LAST_NAME,
        NULL::DATE          AS BIRTH_DATE,
        NULL::VARCHAR(5)    AS CITIZENSHIP,
        PHONE,
        EMAIL,
        ORGANIZATION,
        RECORD_DATE,
        'NICE'              AS SOURCE_SYSTEM,
        1                   AS TRUST_SCORE,
        _SOURCE_FILE
    FROM {{db}}.MDM_RAW_v001.CRMI_RAW_TB_NICE
),

unioned AS (
    SELECT * FROM raw_freg
    UNION ALL
    SELECT * FROM raw_bs
    UNION ALL
    SELECT * FROM raw_nice
),

-- ---------------------------------------------------------------------------
-- SSN modulus-11 — split the 11-digit string into individual digit columns.
-- Rows where SSN is NULL or non-numeric get NULL digits; the final flag
-- resolves to FALSE for those rows without extra CASE branches downstream.
-- ---------------------------------------------------------------------------
ssn_digits AS (
    SELECT
        u.*,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN,  1, 1)::INT END AS d1,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN,  2, 1)::INT END AS d2,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN,  3, 1)::INT END AS d3,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN,  4, 1)::INT END AS d4,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN,  5, 1)::INT END AS d5,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN,  6, 1)::INT END AS d6,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN,  7, 1)::INT END AS d7,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN,  8, 1)::INT END AS d8,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN,  9, 1)::INT END AS d9,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN, 10, 1)::INT END AS d10,
        CASE WHEN u.SSN IS NOT NULL AND u.SSN RLIKE '^[0-9]{11}$'
             THEN SUBSTR(u.SSN, 11, 1)::INT END AS d11
    FROM unioned u
),

-- Compute the two weighted sums modulo 11.
-- r1 remainder for control digit 1 (d10); r2 for control digit 2 (d11).
ssn_weighted AS (
    SELECT
        sd.*,
        CASE WHEN sd.d1 IS NOT NULL THEN
            MOD(3*sd.d1 + 7*sd.d2 + 6*sd.d3 + 1*sd.d4 + 8*sd.d5 +
                9*sd.d6 + 4*sd.d7 + 5*sd.d8 + 2*sd.d9, 11)
        END AS r1,
        CASE WHEN sd.d1 IS NOT NULL THEN
            MOD(5*sd.d1 + 4*sd.d2 + 3*sd.d3 + 2*sd.d4 + 7*sd.d5 +
                6*sd.d6 + 5*sd.d7 + 4*sd.d8 + 3*sd.d9 + 2*sd.d10, 11)
        END AS r2
    FROM ssn_digits sd
),

-- Derive k1/k2 (the expected control digits) and compare to d10/d11.
-- Rule: if remainder = 0 → control digit = 0;
--       if remainder = 1 → no valid 1-digit check exists → INVALID;
--       otherwise        → control digit = 11 - remainder.
ssn_validated AS (
    SELECT
        sw.SSN,
        sw.FIRST_NAME,
        sw.LAST_NAME,
        sw.BIRTH_DATE,
        sw.CITIZENSHIP,
        sw.PHONE,
        sw.EMAIL,
        sw.ORGANIZATION,
        sw.RECORD_DATE,
        sw.SOURCE_SYSTEM,
        sw.TRUST_SCORE,
        sw._SOURCE_FILE,
        CASE
            WHEN sw.SSN IS NULL
              OR NOT (sw.SSN RLIKE '^[0-9]{11}$')        THEN FALSE
            WHEN sw.r1 = 1 OR sw.r2 = 1                  THEN FALSE  -- digit 10 impossible
            WHEN (CASE WHEN sw.r1 = 0 THEN 0 ELSE 11 - sw.r1 END) != sw.d10 THEN FALSE
            WHEN (CASE WHEN sw.r2 = 0 THEN 0 ELSE 11 - sw.r2 END) != sw.d11 THEN FALSE
            ELSE TRUE
        END AS SSN_VALID
    FROM ssn_weighted sw
)

-- Final SELECT: add canonical first name and stable row key.
SELECT
    sv.*,
    COALESCE(nn.canonical, UPPER(sv.FIRST_NAME))       AS CANONICAL_FIRST_NAME,
    -- Synthetic row key for rows where SSN is absent (NICE null-SSN records).
    MD5(
        sv.SOURCE_SYSTEM || '|' ||
        COALESCE(sv.SSN, '') || '|' ||
        COALESCE(sv.FIRST_NAME, '') || '|' ||
        COALESCE(sv.LAST_NAME, '') || '|' ||
        sv.RECORD_DATE::VARCHAR || '|' ||
        COALESCE(sv.ORGANIZATION, '')
    )                                                   AS ROW_KEY
FROM ssn_validated sv
LEFT JOIN nicknames nn
    ON UPPER(sv.FIRST_NAME) = nn.nickname
;


-- =============================================================================
-- 2. CRMI_AGG_DT_GROUPS
--    Entity resolution layer.  Three paths produce MATCH_ID + confidence:
--      A. SSN_EXACT   — SSN present and passes mod-11  → conf 100
--      B. FUZZY_JW    — SSN null; Jaro-Winkler avg ≥ 92 on canonical name → conf 85
--      C. UNMATCHED / INVALID_SSN → STEWARD_QUEUE_FLAG = TRUE
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMI_AGG_DT_GROUPS
    TARGET_LAG   = DOWNSTREAM
    WAREHOUSE    = {{warehouse}}
    REFRESH_MODE = FULL
    COMMENT      = 'Layer 2 – Entity resolution: SSN exact match (conf 100), Jaro-Winkler fuzzy fallback on canonical name (conf 85, threshold 92/100), or steward queue flag for unresolved records.'
AS
WITH

-- Path A: records where SSN passed the mod-11 checksum.
ssn_exact AS (
    SELECT
        ROW_KEY,
        SSN,
        FIRST_NAME,
        LAST_NAME,
        CANONICAL_FIRST_NAME,
        BIRTH_DATE,
        CITIZENSHIP,
        PHONE,
        EMAIL,
        ORGANIZATION,
        RECORD_DATE,
        SOURCE_SYSTEM,
        TRUST_SCORE,
        SSN_VALID,
        _SOURCE_FILE,
        SSN                 AS MATCH_ID,
        100                 AS MATCH_CONFIDENCE,
        'SSN_EXACT'         AS MATCH_METHOD,
        FALSE               AS STEWARD_QUEUE_FLAG,
        NULL::NUMBER(5,2)   AS FUZZY_SCORE,
        NULL::VARCHAR(11)   AS CANDIDATE_SSN
    FROM {{db}}.{{agg_schema}}.CRMI_AGG_DT_ENRICHED
    WHERE SSN_VALID = TRUE
),

-- Invalid SSN (present but fails checksum) — goes straight to steward queue.
invalid_ssn AS (
    SELECT
        ROW_KEY,
        SSN,
        FIRST_NAME,
        LAST_NAME,
        CANONICAL_FIRST_NAME,
        BIRTH_DATE,
        CITIZENSHIP,
        PHONE,
        EMAIL,
        ORGANIZATION,
        RECORD_DATE,
        SOURCE_SYSTEM,
        TRUST_SCORE,
        SSN_VALID,
        _SOURCE_FILE,
        NULL::VARCHAR(11)   AS MATCH_ID,
        0                   AS MATCH_CONFIDENCE,
        'INVALID_SSN'       AS MATCH_METHOD,
        TRUE                AS STEWARD_QUEUE_FLAG,
        NULL::NUMBER(5,2)   AS FUZZY_SCORE,
        NULL::VARCHAR(11)   AS CANDIDATE_SSN
    FROM {{db}}.{{agg_schema}}.CRMI_AGG_DT_ENRICHED
    WHERE SSN IS NOT NULL AND SSN_VALID = FALSE
),

-- Records without an SSN — attempt Jaro-Winkler fuzzy match.
no_ssn_records AS (
    SELECT *
    FROM {{db}}.{{agg_schema}}.CRMI_AGG_DT_ENRICHED
    WHERE SSN IS NULL
),

-- Unique canonical name + SSN combos to match against.
fuzzy_candidates AS (
    SELECT DISTINCT
        SSN                             AS CANDIDATE_SSN,
        CANONICAL_FIRST_NAME            AS CAND_CANONICAL_FIRST,
        UPPER(LAST_NAME)                AS CAND_LAST_UPPER
    FROM {{db}}.{{agg_schema}}.CRMI_AGG_DT_ENRICHED
    WHERE SSN_VALID = TRUE
),

-- Cross-join no-SSN records with candidates; compute per-field JW scores.
fuzzy_scores AS (
    SELECT
        n.ROW_KEY,
        n.SSN,
        n.FIRST_NAME,
        n.LAST_NAME,
        n.CANONICAL_FIRST_NAME,
        n.BIRTH_DATE,
        n.CITIZENSHIP,
        n.PHONE,
        n.EMAIL,
        n.ORGANIZATION,
        n.RECORD_DATE,
        n.SOURCE_SYSTEM,
        n.TRUST_SCORE,
        n.SSN_VALID,
        n._SOURCE_FILE,
        fc.CANDIDATE_SSN,
        JAROWINKLER_SIMILARITY(
            n.CANONICAL_FIRST_NAME,
            fc.CAND_CANONICAL_FIRST
        )                                                       AS JW_FIRST,
        JAROWINKLER_SIMILARITY(
            UPPER(n.LAST_NAME),
            fc.CAND_LAST_UPPER
        )                                                       AS JW_LAST,
        (
            JAROWINKLER_SIMILARITY(n.CANONICAL_FIRST_NAME, fc.CAND_CANONICAL_FIRST) +
            JAROWINKLER_SIMILARITY(UPPER(n.LAST_NAME),     fc.CAND_LAST_UPPER)
        ) / 2.0                                                 AS JW_COMBINED
    FROM no_ssn_records n
    CROSS JOIN fuzzy_candidates fc
),

-- Pre-compute the max JW score per no-SSN record so it can be referenced
-- inside the GROUP BY aggregate in the unmatched CTE below.
-- (Window functions cannot be nested directly inside aggregate functions.)
fuzzy_scores_ranked AS (
    SELECT *,
        MAX(JW_COMBINED) OVER (PARTITION BY ROW_KEY) AS MAX_JW_PER_ROW
    FROM fuzzy_scores
),

-- Best candidate per no-SSN record; keep only matches at or above threshold.
best_fuzzy AS (
    SELECT *
    FROM fuzzy_scores_ranked
    WHERE JW_COMBINED >= 92
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ROW_KEY ORDER BY JW_COMBINED DESC) = 1
),

-- Path B: fuzzy-matched records.
fuzzy_matched AS (
    SELECT
        bf.ROW_KEY,
        bf.SSN,
        bf.FIRST_NAME,
        bf.LAST_NAME,
        bf.CANONICAL_FIRST_NAME,
        bf.BIRTH_DATE,
        bf.CITIZENSHIP,
        bf.PHONE,
        bf.EMAIL,
        bf.ORGANIZATION,
        bf.RECORD_DATE,
        bf.SOURCE_SYSTEM,
        bf.TRUST_SCORE,
        bf.SSN_VALID,
        bf._SOURCE_FILE,
        bf.CANDIDATE_SSN        AS MATCH_ID,
        85                      AS MATCH_CONFIDENCE,
        'FUZZY_JW'              AS MATCH_METHOD,
        FALSE                   AS STEWARD_QUEUE_FLAG,
        bf.JW_COMBINED          AS FUZZY_SCORE,
        bf.CANDIDATE_SSN        AS CANDIDATE_SSN
    FROM best_fuzzy bf
),

-- Path C: no-SSN records that found no fuzzy match above threshold.
unmatched AS (
    SELECT
        n.ROW_KEY,
        n.SSN,
        n.FIRST_NAME,
        n.LAST_NAME,
        n.CANONICAL_FIRST_NAME,
        n.BIRTH_DATE,
        n.CITIZENSHIP,
        n.PHONE,
        n.EMAIL,
        n.ORGANIZATION,
        n.RECORD_DATE,
        n.SOURCE_SYSTEM,
        n.TRUST_SCORE,
        n.SSN_VALID,
        n._SOURCE_FILE,
        NULL::VARCHAR(11)   AS MATCH_ID,
        0                   AS MATCH_CONFIDENCE,
        'UNMATCHED'         AS MATCH_METHOD,
        TRUE                AS STEWARD_QUEUE_FLAG,
        -- Carry the best score attempted even though it was below threshold.
        MAX(fs.JW_COMBINED)                                                     AS FUZZY_SCORE,
        MAX(CASE WHEN fs.JW_COMBINED = fs.MAX_JW_PER_ROW THEN fs.CANDIDATE_SSN END)
                                                                                AS CANDIDATE_SSN
    FROM no_ssn_records n
    LEFT JOIN fuzzy_scores_ranked fs
        ON fs.ROW_KEY = n.ROW_KEY
    WHERE NOT EXISTS (
        SELECT 1 FROM best_fuzzy bf WHERE bf.ROW_KEY = n.ROW_KEY
    )
    GROUP BY
        n.ROW_KEY, n.SSN, n.FIRST_NAME, n.LAST_NAME, n.CANONICAL_FIRST_NAME,
        n.BIRTH_DATE, n.CITIZENSHIP, n.PHONE, n.EMAIL, n.ORGANIZATION,
        n.RECORD_DATE, n.SOURCE_SYSTEM, n.TRUST_SCORE, n.SSN_VALID, n._SOURCE_FILE
)

SELECT * FROM ssn_exact
UNION ALL
SELECT * FROM invalid_ssn
UNION ALL
SELECT * FROM fuzzy_matched
UNION ALL
SELECT * FROM unmatched
;


-- =============================================================================
-- 3. CRMI_AGG_DT_GOLDEN
--    Org-partitioned survivorship.  One golden record per (MATCH_ID, ORGANIZATION).
--    Trust order:  FREG (3) > BS (2) > NICE (1)
--    Name/demographics : highest-trust source wins (most recent within tier).
--    Contact (phone/email): BS first, then NICE  (FREG has none).
--    CUSTOMER_ID is a stable MD5 surrogate derived from (MATCH_ID, ORGANIZATION).
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMI_AGG_DT_GOLDEN
    TARGET_LAG   = DOWNSTREAM
    WAREHOUSE    = {{warehouse}}
    REFRESH_MODE = FULL
    COMMENT      = 'Layer 3 – Golden record: org-partitioned survivorship (FREG>BS>NICE). One row per (MATCH_ID, ORGANIZATION). CUSTOMER_ID = MD5(MATCH_ID||ORG).'
AS
WITH

-- Only matched records with a known organisation contribute to golden records.
matched AS (
    SELECT *
    FROM {{db}}.{{agg_schema}}.CRMI_AGG_DT_GROUPS
    WHERE MATCH_ID      IS NOT NULL
      AND ORGANIZATION  IS NOT NULL
      AND STEWARD_QUEUE_FLAG = FALSE
),

-- Apply survivorship via window functions.
-- One row per source record, but all golden attributes pre-computed via windows.
survivorship AS (
    SELECT
        MATCH_ID,
        ORGANIZATION,
        RECORD_DATE,
        SOURCE_SYSTEM,
        TRUST_SCORE,
        -- Identity: highest-trust source wins; ROWS frame spans full partition.
        -- NOTE: IGNORE NULLS must be inside the function call, not after OVER.
        -- Named WINDOW clauses are not used; inline specs avoid parse issues in DTs.
        FIRST_VALUE(FIRST_NAME IGNORE NULLS) OVER (
            PARTITION BY MATCH_ID, ORGANIZATION
            ORDER BY TRUST_SCORE DESC, RECORD_DATE DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                                                    AS GOLDEN_FIRST_NAME,
        FIRST_VALUE(LAST_NAME IGNORE NULLS) OVER (
            PARTITION BY MATCH_ID, ORGANIZATION
            ORDER BY TRUST_SCORE DESC, RECORD_DATE DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                                                    AS GOLDEN_LAST_NAME,
        -- Demographics: FREG only — no ORDER BY; partition-wide aggregate.
        MAX(CASE WHEN SOURCE_SYSTEM = 'FREG' THEN BIRTH_DATE  END) OVER (
            PARTITION BY MATCH_ID, ORGANIZATION
        )                                                    AS GOLDEN_BIRTH_DATE,
        MAX(CASE WHEN SOURCE_SYSTEM = 'FREG' THEN CITIZENSHIP END) OVER (
            PARTITION BY MATCH_ID, ORGANIZATION
        )                                                    AS GOLDEN_CITIZENSHIP,
        -- Contact: BS preferred over NICE; FREG excluded via trust-ordering trick.
        FIRST_VALUE(PHONE IGNORE NULLS) OVER (
            PARTITION BY MATCH_ID, ORGANIZATION
            ORDER BY CASE WHEN SOURCE_SYSTEM = 'FREG' THEN 0 ELSE TRUST_SCORE END DESC,
                     RECORD_DATE DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                                                    AS GOLDEN_PHONE,
        FIRST_VALUE(EMAIL IGNORE NULLS) OVER (
            PARTITION BY MATCH_ID, ORGANIZATION
            ORDER BY CASE WHEN SOURCE_SYSTEM = 'FREG' THEN 0 ELSE TRUST_SCORE END DESC,
                     RECORD_DATE DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                                                    AS GOLDEN_EMAIL,
        -- Metadata: partition-wide aggregates, no ORDER BY needed.
        COUNT(DISTINCT SOURCE_SYSTEM) OVER (
            PARTITION BY MATCH_ID, ORGANIZATION
        )                                                    AS SOURCE_COUNT,
        MAX(RECORD_DATE) OVER (
            PARTITION BY MATCH_ID, ORGANIZATION
        )                                                    AS LAST_SEEN_DATE
    FROM matched
),

-- Collapse to one row per (MATCH_ID, ORGANIZATION) — pick the highest-trust row.
deduped AS (
    SELECT *
    FROM survivorship
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY MATCH_ID, ORGANIZATION
        ORDER BY TRUST_SCORE DESC, RECORD_DATE DESC
    ) = 1
)

SELECT
    -- Stable synthetic surrogate key.
    MD5(MATCH_ID || '::' || ORGANIZATION)   AS CUSTOMER_ID,
    MATCH_ID,
    ORGANIZATION,
    GOLDEN_FIRST_NAME                        AS FIRST_NAME,
    GOLDEN_LAST_NAME                         AS LAST_NAME,
    GOLDEN_BIRTH_DATE                        AS BIRTH_DATE,
    GOLDEN_CITIZENSHIP                       AS CITIZENSHIP,
    GOLDEN_PHONE                             AS PHONE,
    GOLDEN_EMAIL                             AS EMAIL,
    SOURCE_COUNT,
    LAST_SEEN_DATE,
    -- Data quality score: completeness-based (max 100).
    (
        CASE WHEN GOLDEN_FIRST_NAME  IS NOT NULL THEN 30 ELSE 0 END +
        CASE WHEN GOLDEN_LAST_NAME   IS NOT NULL THEN 30 ELSE 0 END +
        CASE WHEN GOLDEN_PHONE       IS NOT NULL THEN 20 ELSE 0 END +
        CASE WHEN GOLDEN_EMAIL       IS NOT NULL THEN 20 ELSE 0 END
    )                                        AS DQ_SCORE
FROM deduped
;


-- =============================================================================
-- 4. CRMI_AGG_DT_CURRENT
--    Current-state layer.  One row per golden customer per organization with an
--    added SHA2-256 row hash for downstream SCD2 change detection and a refresh
--    timestamp for pipeline observability.
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMI_AGG_DT_CURRENT
    TARGET_LAG   = '{{dt_lag}}'
    WAREHOUSE    = {{warehouse}}
    REFRESH_MODE = FULL
    COMMENT      = 'Layer 4 – Current state: one row per (CUSTOMER_ID, ORGANIZATION) with ROW_HASH (SHA2-256) and pipeline refresh timestamp. Terminal DT — drives 60-min refresh cadence.'
AS
SELECT
    CUSTOMER_ID,
    MATCH_ID,
    ORGANIZATION,
    FIRST_NAME,
    LAST_NAME,
    BIRTH_DATE,
    CITIZENSHIP,
    PHONE,
    EMAIL,
    SOURCE_COUNT,
    LAST_SEEN_DATE,
    DQ_SCORE,
    -- SHA2-256 hash over all tracked attributes for change detection.
    SHA2(
        CONCAT_WS('::',
            COALESCE(FIRST_NAME,    ''),
            COALESCE(LAST_NAME,     ''),
            COALESCE(PHONE,         ''),
            COALESCE(EMAIL,         ''),
            COALESCE(BIRTH_DATE::VARCHAR, ''),
            COALESCE(CITIZENSHIP,   '')
        ),
        256
    )                                   AS ROW_HASH,
    'v001'                              AS PIPELINE_VERSION,
    CURRENT_TIMESTAMP()                 AS PIPELINE_REFRESHED_AT
FROM {{db}}.{{agg_schema}}.CRMI_AGG_DT_GOLDEN
;


-- =============================================================================
-- 5. CRMI_AGG_DT_HISTORY
--    SCD Type 2 history.  Exploits the append-only nature of the RAW tables:
--    each distinct RECORD_DATE for a (MATCH_ID, ORGANIZATION) represents a
--    potential state boundary.  Survivorship is re-computed at each boundary
--    using only records available on or before that date.  Consecutive versions
--    with an identical SHA2 row hash are collapsed (no-op snapshots dropped).
--
--    Columns:
--      VALID_FROM  — date this version became effective (= snapshot RECORD_DATE)
--      VALID_TO    — date superseded (next boundary), or 9999-12-31 if current
--      IS_VALID    — TRUE only for the current (open-ended) version
--      ROW_HASH    — SHA2-256 of tracked attributes for change detection
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMI_AGG_DT_HISTORY
    TARGET_LAG   = '{{dt_lag}}'
    WAREHOUSE    = {{warehouse}}
    REFRESH_MODE = FULL
    COMMENT      = 'Layer 5 – SCD Type 2 history: all attribute versions reconstructed from append-only raw snapshots. ROW_HASH detects real changes; consecutive no-op versions are collapsed.'
AS
WITH

-- Enumerate every distinct (MATCH_ID, ORG, RECORD_DATE) that contributed a
-- matched record — these are our version boundaries.
snapshot_boundaries AS (
    SELECT DISTINCT
        MATCH_ID,
        ORGANIZATION,
        RECORD_DATE                 AS SNAPSHOT_DATE
    FROM {{db}}.{{agg_schema}}.CRMI_AGG_DT_GROUPS
    WHERE MATCH_ID              IS NOT NULL
      AND ORGANIZATION          IS NOT NULL
      AND STEWARD_QUEUE_FLAG    = FALSE
),

-- For each (MATCH_ID, ORG, SNAPSHOT_DATE), re-apply survivorship using only
-- the records from GROUPS that were available on or before that snapshot date.
versioned_survivorship AS (
    SELECT
        sb.MATCH_ID,
        sb.ORGANIZATION,
        sb.SNAPSHOT_DATE,
        g.SOURCE_SYSTEM,
        g.TRUST_SCORE,
        g.FIRST_NAME,
        g.LAST_NAME,
        g.BIRTH_DATE,
        g.CITIZENSHIP,
        g.PHONE,
        g.EMAIL,
        g.RECORD_DATE,
        -- Identity survivorship window scoped to records ≤ snapshot date.
        FIRST_VALUE(g.FIRST_NAME IGNORE NULLS) OVER (
            PARTITION BY sb.MATCH_ID, sb.ORGANIZATION, sb.SNAPSHOT_DATE
            ORDER BY g.TRUST_SCORE DESC, g.RECORD_DATE DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                           AS SNAP_FIRST_NAME,
        FIRST_VALUE(g.LAST_NAME IGNORE NULLS) OVER (
            PARTITION BY sb.MATCH_ID, sb.ORGANIZATION, sb.SNAPSHOT_DATE
            ORDER BY g.TRUST_SCORE DESC, g.RECORD_DATE DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                           AS SNAP_LAST_NAME,
        -- Demographics: FREG only — no ORDER BY; partition-wide aggregate.
        MAX(CASE WHEN g.SOURCE_SYSTEM = 'FREG' THEN g.BIRTH_DATE  END) OVER (
            PARTITION BY sb.MATCH_ID, sb.ORGANIZATION, sb.SNAPSHOT_DATE
        )                           AS SNAP_BIRTH_DATE,
        MAX(CASE WHEN g.SOURCE_SYSTEM = 'FREG' THEN g.CITIZENSHIP END) OVER (
            PARTITION BY sb.MATCH_ID, sb.ORGANIZATION, sb.SNAPSHOT_DATE
        )                           AS SNAP_CITIZENSHIP,
        FIRST_VALUE(g.PHONE IGNORE NULLS) OVER (
            PARTITION BY sb.MATCH_ID, sb.ORGANIZATION, sb.SNAPSHOT_DATE
            ORDER BY CASE WHEN g.SOURCE_SYSTEM = 'FREG' THEN 0 ELSE g.TRUST_SCORE END DESC,
                     g.RECORD_DATE DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                           AS SNAP_PHONE,
        FIRST_VALUE(g.EMAIL IGNORE NULLS) OVER (
            PARTITION BY sb.MATCH_ID, sb.ORGANIZATION, sb.SNAPSHOT_DATE
            ORDER BY CASE WHEN g.SOURCE_SYSTEM = 'FREG' THEN 0 ELSE g.TRUST_SCORE END DESC,
                     g.RECORD_DATE DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )                           AS SNAP_EMAIL,
        COUNT(DISTINCT g.SOURCE_SYSTEM) OVER (
            PARTITION BY sb.MATCH_ID, sb.ORGANIZATION, sb.SNAPSHOT_DATE
        )                           AS SNAP_SOURCE_COUNT
    FROM snapshot_boundaries sb
    JOIN {{db}}.{{agg_schema}}.CRMI_AGG_DT_GROUPS g
        ON  g.MATCH_ID          = sb.MATCH_ID
        AND g.ORGANIZATION      = sb.ORGANIZATION
        AND g.RECORD_DATE       <= sb.SNAPSHOT_DATE
        AND g.STEWARD_QUEUE_FLAG = FALSE
),

-- Deduplicate to one row per (MATCH_ID, ORG, SNAPSHOT_DATE).
one_per_snapshot AS (
    SELECT *
    FROM versioned_survivorship
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY MATCH_ID, ORGANIZATION, SNAPSHOT_DATE
        ORDER BY TRUST_SCORE DESC, RECORD_DATE DESC
    ) = 1
),

-- Compute SHA2 hash and lag to detect changes.
-- NOTE: 'ops' alias must be declared on the FROM clause: FROM one_per_snapshot ops
with_hash AS (
    SELECT
        ops.*,
        SHA2(
            CONCAT_WS('::',
                COALESCE(ops.SNAP_FIRST_NAME,    ''),
                COALESCE(ops.SNAP_LAST_NAME,     ''),
                COALESCE(ops.SNAP_PHONE,         ''),
                COALESCE(ops.SNAP_EMAIL,         ''),
                COALESCE(ops.SNAP_BIRTH_DATE::VARCHAR, ''),
                COALESCE(ops.SNAP_CITIZENSHIP,   '')
            ),
            256
        )                               AS ROW_HASH,
        LAG(SHA2(
            CONCAT_WS('::',
                COALESCE(ops.SNAP_FIRST_NAME,    ''),
                COALESCE(ops.SNAP_LAST_NAME,     ''),
                COALESCE(ops.SNAP_PHONE,         ''),
                COALESCE(ops.SNAP_EMAIL,         ''),
                COALESCE(ops.SNAP_BIRTH_DATE::VARCHAR, ''),
                COALESCE(ops.SNAP_CITIZENSHIP,   '')
            ),
            256
        )) OVER (
            PARTITION BY ops.MATCH_ID, ops.ORGANIZATION
            ORDER BY ops.SNAPSHOT_DATE
        )                               AS PREV_ROW_HASH,
        LEAD(ops.SNAPSHOT_DATE) OVER (
            PARTITION BY ops.MATCH_ID, ops.ORGANIZATION
            ORDER BY ops.SNAPSHOT_DATE
        )                               AS NEXT_SNAPSHOT_DATE
    FROM one_per_snapshot ops
)

-- Emit only rows where something actually changed (collapse no-op snapshots).
-- The very first version for a customer always passes (PREV_ROW_HASH IS NULL).
SELECT
    MD5(MATCH_ID || '::' || ORGANIZATION)   AS CUSTOMER_ID,
    MATCH_ID,
    ORGANIZATION,
    SNAP_FIRST_NAME                          AS FIRST_NAME,
    SNAP_LAST_NAME                           AS LAST_NAME,
    SNAP_BIRTH_DATE                          AS BIRTH_DATE,
    SNAP_CITIZENSHIP                         AS CITIZENSHIP,
    SNAP_PHONE                               AS PHONE,
    SNAP_EMAIL                               AS EMAIL,
    SNAP_SOURCE_COUNT                        AS SOURCE_COUNT,
    ROW_HASH,
    SNAPSHOT_DATE                            AS VALID_FROM,
    COALESCE(NEXT_SNAPSHOT_DATE, '9999-12-31'::DATE)
                                             AS VALID_TO,
    (NEXT_SNAPSHOT_DATE IS NULL)             AS IS_VALID
FROM with_hash
WHERE ROW_HASH != COALESCE(PREV_ROW_HASH, '')
;


-- =============================================================================
-- 6. CRMI_AGG_DT_STEWARD_QUEUE
--    Surfaces all records that could not be resolved to a golden customer:
--      • INVALID_SSN       — SSN present but fails mod-11 checksum
--      • UNMATCHED         — SSN absent and no Jaro-Winkler match ≥ 92
--    Intended for a data steward UI or manual review workflow.
--    REVIEWED defaults to FALSE; update it externally once actioned.
-- =============================================================================

CREATE OR REPLACE DYNAMIC TABLE {{db}}.{{agg_schema}}.CRMI_AGG_DT_STEWARD_QUEUE
    TARGET_LAG   = '{{dt_lag}}'
    WAREHOUSE    = {{warehouse}}
    REFRESH_MODE = FULL
    COMMENT      = 'Layer 6 – Steward queue: records unresolved by SSN exact match and Jaro-Winkler fuzzy matching. Reasons: INVALID_SSN_CHECKSUM | NO_SSN_NO_FUZZY_MATCH. REVIEWED flag for steward tooling.'
AS
SELECT
    ROW_KEY,
    SOURCE_SYSTEM,
    SSN,
    FIRST_NAME,
    LAST_NAME,
    PHONE,
    EMAIL,
    ORGANIZATION,
    RECORD_DATE,
    _SOURCE_FILE,
    -- Human-readable reason for steward.
    CASE
        WHEN MATCH_METHOD = 'INVALID_SSN' THEN 'INVALID_SSN_CHECKSUM'
        WHEN MATCH_METHOD = 'UNMATCHED'   THEN 'NO_SSN_NO_FUZZY_MATCH'
        ELSE                                   'FUZZY_BELOW_THRESHOLD'
    END                             AS QUEUE_REASON,
    -- Best fuzzy score attempted (NULL for invalid-SSN records where fuzzy
    -- was not tried; populated for UNMATCHED records where fuzzy was tried
    -- but fell below the 92/100 threshold).
    FUZZY_SCORE,
    -- Best candidate SSN found during fuzzy scoring (may be NULL).
    CANDIDATE_SSN,
    CURRENT_TIMESTAMP()             AS QUEUED_AT,
    FALSE                           AS REVIEWED
FROM {{db}}.{{agg_schema}}.CRMI_AGG_DT_GROUPS
WHERE STEWARD_QUEUE_FLAG = TRUE
;
