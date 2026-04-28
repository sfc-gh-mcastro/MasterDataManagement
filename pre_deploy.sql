-- =============================================================================
-- pre_deploy.sql — Database and schema setup (must exist before DCM plan)
-- =============================================================================

CREATE DATABASE IF NOT EXISTS MASTER_DATA_MANAGEMENT
    COMMENT = 'Central repository for unified customer and address master data';

USE DATABASE MASTER_DATA_MANAGEMENT;

CREATE SCHEMA IF NOT EXISTS CRM_RAW_001
    COMMENT = 'Landing zone for raw customer and address data from source systems.';

CREATE SCHEMA IF NOT EXISTS CRM_AGG_001
    COMMENT = 'Entity resolution, survivorship, golden records, and SCD Type 2 history.';

CREATE SCHEMA IF NOT EXISTS CRM_SRV_001
    COMMENT = 'Consumer-ready Customer 360 views for BI tools, APIs, and applications.';

CREATE DCM PROJECT IF NOT EXISTS MASTER_DATA_MANAGEMENT.CRM_AGG_001.MDM_PROJECT;
