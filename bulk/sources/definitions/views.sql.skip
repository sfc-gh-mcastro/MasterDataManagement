-- =============================================================================
-- views.sql — Union views and XREF views for Norwegian banking MDM
-- Sources: FREG (Folkeregisteret), BS (Bank System), NICE (CRM)
-- FREG has no Organization → broadcast to BANK and INS via CROSS JOIN
-- Address raw tables have no Organization → all three broadcast to BANK and INS
-- =============================================================================

DEFINE VIEW {{db}}.{{agg_schema}}.CRMA_AGG_VW_CUSTOMER_UNION
    COMMENT = 'Harmonizes FREG/BS/NICE into unified schema. FREG broadcast to BANK and INS via CROSS JOIN (no Organization in national register).'
AS
-- FREG: national population register, highest trust, no Organization.
-- Each FREG record is emitted twice (BANK + INS) to feed both org golden records.
SELECT
    'FREG'                                  AS SOURCE_SYSTEM,
    SSN                                     AS SOURCE_KEY,
    SSN,
    INITCAP(TRIM(FIRST_NAME))               AS FIRST_NAME,
    INITCAP(TRIM(LAST_NAME))                AS LAST_NAME,
    BIRTH_DATE,
    CITIZENSHIP,
    NULL                                    AS PHONE,
    NULL                                    AS EMAIL,
    RECORD_DATE,
    org.ORGANIZATION,
    _SOURCE_FILE
FROM {{db}}.{{raw_schema}}.CRMI_RAW_TB_FREG
CROSS JOIN (SELECT 'BANK' AS ORGANIZATION UNION ALL SELECT 'INS' AS ORGANIZATION) org

UNION ALL

-- BS: banking system, mid trust, has SSN and Organization
SELECT
    'BS'                                        AS SOURCE_SYSTEM,
    SSN                                         AS SOURCE_KEY,
    SSN,
    INITCAP(TRIM(FIRST_NAME))                   AS FIRST_NAME,
    INITCAP(TRIM(LAST_NAME))                    AS LAST_NAME,
    NULL                                        AS BIRTH_DATE,
    NULL                                        AS CITIZENSHIP,
    REGEXP_REPLACE(PHONE, '[^0-9+]', '')        AS PHONE,
    LOWER(TRIM(EMAIL))                          AS EMAIL,
    RECORD_DATE,
    ORGANIZATION,
    _SOURCE_FILE
FROM {{db}}.{{raw_schema}}.CRMI_RAW_TB_BS

UNION ALL

-- NICE: CRM system, lowest trust, SSN nullable (~30% of records lack SSN)
SELECT
    'NICE'                                      AS SOURCE_SYSTEM,
    COALESCE(
        SSN,
        MD5(CONCAT(
            COALESCE(TRIM(FIRST_NAME), ''),
            COALESCE(TRIM(LAST_NAME), ''),
            COALESCE(REGEXP_REPLACE(PHONE, '[^0-9+]', ''), '')
        ))
    )                                           AS SOURCE_KEY,
    SSN,
    INITCAP(TRIM(FIRST_NAME))                   AS FIRST_NAME,
    INITCAP(TRIM(LAST_NAME))                    AS LAST_NAME,
    NULL                                        AS BIRTH_DATE,
    NULL                                        AS CITIZENSHIP,
    REGEXP_REPLACE(PHONE, '[^0-9+]', '')        AS PHONE,
    LOWER(TRIM(EMAIL))                          AS EMAIL,
    RECORD_DATE,
    ORGANIZATION,
    _SOURCE_FILE
FROM {{db}}.{{raw_schema}}.CRMI_RAW_TB_NICE;


DEFINE VIEW {{db}}.{{agg_schema}}.CRMA_AGG_VW_ADDRESSES_UNION
    COMMENT = 'Harmonizes Norwegian address data from FREG/BS/NICE. None of the address raw tables carry Organization, so all three are broadcast to BANK and INS via CROSS JOIN.'
AS
-- FREG addresses: no Organization → broadcast to BANK and INS
SELECT
    'FREG'                              AS SOURCE_SYSTEM,
    SRC_ADDRESS_ID                      AS SOURCE_KEY,
    SRC_CUSTOMER_ID                     AS SOURCE_CUSTOMER_KEY,
    INITCAP(TRIM(GATE))                 AS GATE,
    TRIM(POSTNUMMER)                    AS POSTNUMMER,
    INITCAP(TRIM("BY"))                   AS "BY",
    UPPER(TRIM(LAND))                   AS LAND,
    org.ORGANIZATION,
    _SOURCE_FILE,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ  AS ROW_TIMESTAMP
FROM {{db}}.{{raw_schema}}.CRMI_RAW_TB_ADDRESSES_FREG
CROSS JOIN (SELECT 'BANK' AS ORGANIZATION UNION ALL SELECT 'INS' AS ORGANIZATION) org

UNION ALL

-- BS addresses: no Organization column → broadcast to BANK and INS
SELECT
    'BS'                                AS SOURCE_SYSTEM,
    SRC_ADDRESS_ID                      AS SOURCE_KEY,
    SRC_CUSTOMER_ID                     AS SOURCE_CUSTOMER_KEY,
    INITCAP(TRIM(GATE))                 AS GATE,
    TRIM(POSTNUMMER)                    AS POSTNUMMER,
    INITCAP(TRIM("BY"))                   AS "BY",
    UPPER(TRIM(LAND))                   AS LAND,
    org.ORGANIZATION,
    _SOURCE_FILE,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ  AS ROW_TIMESTAMP
FROM {{db}}.{{raw_schema}}.CRMI_RAW_TB_ADDRESSES_BS
CROSS JOIN (SELECT 'BANK' AS ORGANIZATION UNION ALL SELECT 'INS' AS ORGANIZATION) org

UNION ALL

-- NICE addresses: no Organization column → broadcast to BANK and INS
SELECT
    'NICE'                              AS SOURCE_SYSTEM,
    SRC_ADDRESS_ID                      AS SOURCE_KEY,
    SRC_CUSTOMER_ID                     AS SOURCE_CUSTOMER_KEY,
    INITCAP(TRIM(GATE))                 AS GATE,
    TRIM(POSTNUMMER)                    AS POSTNUMMER,
    INITCAP(TRIM("BY"))                   AS "BY",
    UPPER(TRIM(LAND))                   AS LAND,
    org.ORGANIZATION,
    _SOURCE_FILE,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ  AS ROW_TIMESTAMP
FROM {{db}}.{{raw_schema}}.CRMI_RAW_TB_ADDRESSES_NICE
CROSS JOIN (SELECT 'BANK' AS ORGANIZATION UNION ALL SELECT 'INS' AS ORGANIZATION) org;


DEFINE VIEW {{db}}.{{agg_schema}}.CRMA_AGG_VW_CUSTOMER_XREF_AI
    COMMENT = 'Cross-reference mapping from source keys to customer group IDs. ORGANIZATION in grain. AI pipeline.'
AS
SELECT
    ROW_NUMBER() OVER (ORDER BY customer_group_id, organization, source_system, source_key) AS xref_id,
    customer_group_id, organization, source_system, source_key,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS created_at
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_AI;


DEFINE VIEW {{db}}.{{agg_schema}}.CRMA_AGG_VW_ADDRESSES_XREF_AI
    COMMENT = 'Cross-reference mapping from source address keys to master address IDs. AI pipeline.'
AS
SELECT
    ROW_NUMBER() OVER (ORDER BY address_id, organization, source_system, source_key) AS xref_id,
    address_id, customer_group_id, organization, source_system, source_key,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS created_at
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GROUPS_AI;


DEFINE VIEW {{db}}.{{agg_schema}}.CRMA_AGG_VW_CUSTOMER_XREF_FUZZY
    COMMENT = 'Cross-reference mapping from source keys to customer group IDs. ORGANIZATION in grain. Fuzzy pipeline.'
AS
SELECT
    ROW_NUMBER() OVER (ORDER BY customer_group_id, organization, source_system, source_key) AS xref_id,
    customer_group_id, organization, source_system, source_key,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS created_at
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_GROUPS_FUZZY;


DEFINE VIEW {{db}}.{{agg_schema}}.CRMA_AGG_VW_ADDRESSES_XREF_FUZZY
    COMMENT = 'Cross-reference mapping from source address keys to master address IDs. Fuzzy pipeline.'
AS
SELECT
    ROW_NUMBER() OVER (ORDER BY address_id, organization, source_system, source_key) AS xref_id,
    address_id, customer_group_id, organization, source_system, source_key,
    CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS created_at
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_GROUPS_FUZZY;
