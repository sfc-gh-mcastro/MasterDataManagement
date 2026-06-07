-- =============================================================================
-- pre_deploy.sql — One-time setup: warehouse, database, schemas, DCM project
-- =============================================================================
-- Edit the values below if you need a different database or schema layout.
-- Run: snow sql -f pre_deploy.sql -c <connection>
-- =============================================================================

CREATE WAREHOUSE IF NOT EXISTS MD_TEST_WH
    WAREHOUSE_SIZE = 'X-SMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    COMMENT = 'Warehouse for MDM pipeline (Dynamic Tables, ingestion tasks)';

CREATE DATABASE IF NOT EXISTS MDM_DEV
    COMMENT = 'Central repository for unified customer and address master data';

CREATE SCHEMA IF NOT EXISTS MDM_DEV.MDM_DCM;
CREATE SCHEMA IF NOT EXISTS MDM_DEV.MDM_RAW_v001
    COMMENT = 'Landing zone for raw customer and address data from source systems.';
CREATE SCHEMA IF NOT EXISTS MDM_DEV.MDM_AGG_v001
    COMMENT = 'Entity resolution, survivorship, golden records, and SCD Type 2 history.';
CREATE SCHEMA IF NOT EXISTS MDM_DEV.MDM_SRV_v001
    COMMENT = 'Consumer-ready Customer 360 views for BI tools, APIs, and applications.';

CREATE DCM PROJECT IF NOT EXISTS MDM_DEV.MDM_DCM.MDM_PROJECT;
