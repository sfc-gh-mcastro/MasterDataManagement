-- =============================================================================
-- infrastructure.sql — Internal stages
-- =============================================================================
-- NOTE: Warehouse MD_TEST_WH is managed by pre_deploy.sql

DEFINE STAGE {{db}}.{{raw_schema}}.CRMI_RAW_ST_FREG
    FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = ',' SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('', 'NULL', 'null') EMPTY_FIELD_AS_NULL = TRUE ENCODING = 'UTF8')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Landing zone for FREG (Folkeregisteret) customer files.';

DEFINE STAGE {{db}}.{{raw_schema}}.CRMI_RAW_ST_BS
    FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = ',' SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('', 'NULL', 'null') EMPTY_FIELD_AS_NULL = TRUE ENCODING = 'UTF8')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Landing zone for BS (Bank System) customer files.';

DEFINE STAGE {{db}}.{{raw_schema}}.CRMI_RAW_ST_NICE
    FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = ',' SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('', 'NULL', 'null', 'N/A') EMPTY_FIELD_AS_NULL = TRUE ENCODING = 'UTF8')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Landing zone for NICE (CRM) customer files.';

DEFINE STAGE {{db}}.{{raw_schema}}.CRMI_RAW_ST_ADDRESSES_FREG
    FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = ',' SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('', 'NULL', 'null') EMPTY_FIELD_AS_NULL = TRUE ENCODING = 'UTF8')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Landing zone for FREG address files.';

DEFINE STAGE {{db}}.{{raw_schema}}.CRMI_RAW_ST_ADDRESSES_BS
    FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = ',' SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('', 'NULL', 'null') EMPTY_FIELD_AS_NULL = TRUE ENCODING = 'UTF8')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Landing zone for BS address files.';

DEFINE STAGE {{db}}.{{raw_schema}}.CRMI_RAW_ST_ADDRESSES_NICE
    FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = ',' SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' NULL_IF = ('', 'NULL', 'null', 'N/A') EMPTY_FIELD_AS_NULL = TRUE ENCODING = 'UTF8')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Landing zone for NICE address files.';
