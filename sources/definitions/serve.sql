-- =============================================================================
-- serve.sql — Customer 360 presentation views
-- =============================================================================

DEFINE VIEW {{db}}.{{srv_schema}}.CRMS_AGG_VW_CUSTOMER_360
    COMMENT = 'Complete customer profile with addresses as nested JSON.'
AS
WITH customer_base AS (
    SELECT c.customer_id, c.first_name, c.last_name, c.first_name || ' ' || c.last_name AS full_name,
        c.email, c.phone, c.dq_score, c.source_count, c.last_updated,
        CASE WHEN c.dq_score >= 90 THEN 'Excellent' WHEN c.dq_score >= 70 THEN 'Good' WHEN c.dq_score >= 50 THEN 'Fair' ELSE 'Poor' END AS dq_tier
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER c
),
addresses_agg AS (
    SELECT customer_id, COUNT(*) AS address_count,
        MAX(CASE WHEN is_primary THEN street END) AS primary_street,
        MAX(CASE WHEN is_primary THEN city END) AS primary_city,
        MAX(CASE WHEN is_primary THEN postal_code END) AS primary_postal_code,
        MAX(CASE WHEN is_primary THEN country END) AS primary_country,
        ARRAY_AGG(OBJECT_CONSTRUCT('address_id', address_id, 'type', address_type, 'street', street, 'city', city, 'postal_code', postal_code, 'country', country, 'is_primary', is_primary)) AS all_addresses
    FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES GROUP BY customer_id
)
SELECT cb.customer_id, cb.first_name, cb.last_name, cb.full_name, cb.email, cb.phone, cb.dq_score, cb.dq_tier,
    cb.source_count, cb.last_updated, COALESCE(aa.address_count, 0) AS address_count,
    aa.primary_street, aa.primary_city, aa.primary_postal_code, aa.primary_country,
    CONCAT_WS(', ', aa.primary_street, aa.primary_city, aa.primary_postal_code, aa.primary_country) AS primary_address_full,
    aa.all_addresses
FROM customer_base cb LEFT JOIN addresses_agg aa ON cb.customer_id = aa.customer_id;

DEFINE VIEW {{db}}.{{srv_schema}}.CRMS_AGG_VW_CUSTOMER_360_FLAT
    COMMENT = 'Flattened customer-address view for BI tools.'
AS
SELECT c.customer_id, c.first_name, c.last_name, c.email, c.phone, c.dq_score,
    CASE WHEN c.dq_score >= 90 THEN 'Excellent' WHEN c.dq_score >= 70 THEN 'Good' WHEN c.dq_score >= 50 THEN 'Fair' ELSE 'Poor' END AS dq_tier,
    c.source_count, c.last_updated, a.address_id, a.address_type, a.street, a.city, a.postal_code, a.country, a.is_primary
FROM {{db}}.{{agg_schema}}.CRMA_AGG_DT_CUSTOMER c
LEFT JOIN {{db}}.{{agg_schema}}.CRMA_AGG_DT_ADDRESSES a ON c.customer_id = a.customer_id;
