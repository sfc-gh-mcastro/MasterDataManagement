-- =============================================================================
-- serve.sql — Customer 360 presentation views (AI and Fuzzy pipelines)
-- =============================================================================

DEFINE VIEW {{db}}.{{srv_schema}}.CRMS_AGG_VW_CUSTOMER_360_AI
    COMMENT = 'Complete customer profile with addresses as nested JSON. AI pipeline.'
AS
WITH customer_base AS (
    SELECT c.customer_group_id, c.first_name, c.last_name, c.first_name || ' ' || c.last_name AS full_name,
        c.email, c.phone, c.dq_score, c.source_count, c.last_updated,
        c.ssn, c.birth_date, c.citizenship, c.organization, c.mdm_processed_date,
        CASE WHEN c.dq_score >= 90 THEN 'Excellent' WHEN c.dq_score >= 70 THEN 'Good' WHEN c.dq_score >= 50 THEN 'Fair' ELSE 'Poor' END AS dq_tier
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_AI c
),
addresses_agg AS (
    SELECT customer_group_id, organization, COUNT(*) AS address_count,
        MAX(CASE WHEN is_primary THEN gate END) AS primary_gate,
        MAX(CASE WHEN is_primary THEN "BY" END) AS primary_by,
        MAX(CASE WHEN is_primary THEN postnummer END) AS primary_postnummer,
        MAX(CASE WHEN is_primary THEN land END) AS primary_land,
        MAX(CASE WHEN is_primary THEN dq_score END) AS primary_address_dq_score,
        ARRAY_AGG(OBJECT_CONSTRUCT('address_id', address_id, 'type', address_type, 'gate', gate, 'by', "BY", 'postnummer', postnummer, 'land', land, 'is_primary', is_primary, 'dq_score', dq_score)) AS all_addresses
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_AI GROUP BY customer_group_id, organization
)
SELECT cb.customer_group_id, cb.first_name, cb.last_name, cb.full_name, cb.email, cb.phone, cb.dq_score, cb.dq_tier,
    cb.source_count, cb.last_updated, cb.ssn, cb.birth_date, cb.citizenship, cb.organization, cb.mdm_processed_date,
    COALESCE(aa.address_count, 0) AS address_count,
    aa.primary_gate, aa.primary_by, aa.primary_postnummer, aa.primary_land,
    CONCAT_WS(', ', aa.primary_gate, aa.primary_by, aa.primary_postnummer, aa.primary_land) AS primary_address_full,
    aa.all_addresses,
    aa.primary_address_dq_score
FROM customer_base cb LEFT JOIN addresses_agg aa ON cb.customer_group_id = aa.customer_group_id AND cb.organization = aa.organization;

DEFINE VIEW {{db}}.{{srv_schema}}.CRMS_AGG_VW_CUSTOMER_360_FLAT_AI
    COMMENT = 'Flattened customer-address view for BI tools. AI pipeline.'
AS
SELECT c.customer_group_id, c.first_name, c.last_name, c.email, c.phone, c.dq_score,
    CASE WHEN c.dq_score >= 90 THEN 'Excellent' WHEN c.dq_score >= 70 THEN 'Good' WHEN c.dq_score >= 50 THEN 'Fair' ELSE 'Poor' END AS dq_tier,
    c.source_count, c.last_updated, c.ssn, c.birth_date, c.citizenship, c.organization, c.mdm_processed_date,
    a.address_id, a.address_type, a.gate, a."BY" AS city, a.postnummer, a.land, a.is_primary, a.dq_score AS address_dq_score
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_AI c
LEFT JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_AI a ON a.customer_group_id = c.customer_group_id AND a.organization = c.organization;

DEFINE VIEW {{db}}.{{srv_schema}}.CRMS_AGG_VW_CUSTOMER_360_FUZZY
    COMMENT = 'Complete customer profile with addresses as nested JSON. Fuzzy pipeline.'
AS
WITH customer_base AS (
    SELECT c.customer_group_id, c.first_name, c.last_name, c.first_name || ' ' || c.last_name AS full_name,
        c.email, c.phone, c.dq_score, c.source_count, c.last_updated,
        c.ssn, c.birth_date, c.citizenship, c.organization, c.mdm_processed_date,
        CASE WHEN c.dq_score >= 90 THEN 'Excellent' WHEN c.dq_score >= 70 THEN 'Good' WHEN c.dq_score >= 50 THEN 'Fair' ELSE 'Poor' END AS dq_tier
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_FUZZY c
),
addresses_agg AS (
    SELECT customer_group_id, organization, COUNT(*) AS address_count,
        MAX(CASE WHEN is_primary THEN gate END) AS primary_gate,
        MAX(CASE WHEN is_primary THEN "BY" END) AS primary_by,
        MAX(CASE WHEN is_primary THEN postnummer END) AS primary_postnummer,
        MAX(CASE WHEN is_primary THEN land END) AS primary_land,
        MAX(CASE WHEN is_primary THEN dq_score END) AS primary_address_dq_score,
        ARRAY_AGG(OBJECT_CONSTRUCT('address_id', address_id, 'type', address_type, 'gate', gate, 'by', "BY", 'postnummer', postnummer, 'land', land, 'is_primary', is_primary, 'dq_score', dq_score)) AS all_addresses
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_FUZZY GROUP BY customer_group_id, organization
)
SELECT cb.customer_group_id, cb.first_name, cb.last_name, cb.full_name, cb.email, cb.phone, cb.dq_score, cb.dq_tier,
    cb.source_count, cb.last_updated, cb.ssn, cb.birth_date, cb.citizenship, cb.organization, cb.mdm_processed_date,
    COALESCE(aa.address_count, 0) AS address_count,
    aa.primary_gate, aa.primary_by, aa.primary_postnummer, aa.primary_land,
    CONCAT_WS(', ', aa.primary_gate, aa.primary_by, aa.primary_postnummer, aa.primary_land) AS primary_address_full,
    aa.all_addresses,
    aa.primary_address_dq_score
FROM customer_base cb LEFT JOIN addresses_agg aa ON cb.customer_group_id = aa.customer_group_id AND cb.organization = aa.organization;

DEFINE VIEW {{db}}.{{srv_schema}}.CRMS_AGG_VW_CUSTOMER_360_FLAT_FUZZY
    COMMENT = 'Flattened customer-address view for BI tools. Fuzzy pipeline.'
AS
SELECT c.customer_group_id, c.first_name, c.last_name, c.email, c.phone, c.dq_score,
    CASE WHEN c.dq_score >= 90 THEN 'Excellent' WHEN c.dq_score >= 70 THEN 'Good' WHEN c.dq_score >= 50 THEN 'Fair' ELSE 'Poor' END AS dq_tier,
    c.source_count, c.last_updated, c.ssn, c.birth_date, c.citizenship, c.organization, c.mdm_processed_date,
    a.address_id, a.address_type, a.gate, a."BY" AS city, a.postnummer, a.land, a.is_primary, a.dq_score AS address_dq_score
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_FUZZY c
LEFT JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES_FUZZY a ON a.customer_group_id = c.customer_group_id AND a.organization = c.organization;

DEFINE VIEW {{db}}.{{srv_schema}}.CRMS_AGG_VW_CUSTOMER_360_CROSS_ORG
    COMMENT = 'Customers identified in both BANK and INS organizations via SSN linkage.'
AS
SELECT
    b.SSN,
    b.FIRST_NAME AS BANK_FIRST_NAME,
    b.LAST_NAME AS BANK_LAST_NAME,
    b.EMAIL AS BANK_EMAIL,
    b.PHONE AS BANK_PHONE,
    i.FIRST_NAME AS INS_FIRST_NAME,
    i.LAST_NAME AS INS_LAST_NAME,
    i.EMAIL AS INS_EMAIL,
    i.PHONE AS INS_PHONE,
    b.CITIZENSHIP,
    b.BIRTH_DATE,
    b.MDM_PROCESSED_DATE
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_AI b
JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER_AI i
    ON b.SSN = i.SSN AND b.ORGANIZATION = 'BANK' AND i.ORGANIZATION = 'INS';
