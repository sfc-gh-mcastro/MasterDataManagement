-- =============================================================================
-- raw_tables.sql — Append-only RAW tables for Norwegian MDM ingestion
-- Source systems: FREG (national register), BS (bank system), NICE (CRM)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Customer tables
-- ---------------------------------------------------------------------------

DEFINE TABLE {{db}}.{{raw_schema}}.CRMI_RAW_TB_FREG (
    SSN           VARCHAR(11)  NOT NULL COMMENT 'Norwegian personnummer (DDMMYYXXXCC, modulus-11)',
    FIRST_NAME    VARCHAR(100) COMMENT 'Given name as recorded in Folkeregisteret',
    LAST_NAME     VARCHAR(100) COMMENT 'Family name as recorded in Folkeregisteret',
    BIRTH_DATE    DATE         COMMENT 'Date of birth derived from personnummer',
    CITIZENSHIP   VARCHAR(5)   COMMENT 'ISO 3166-1 alpha-2 country code (NO, SE, PL, LT, ...)',
    RECORD_DATE   DATE         COMMENT 'Date this record was effective in FREG',
    _SOURCE_FILE  VARCHAR(500) COMMENT 'Source filename for data lineage (metadata$filename)'
)
COMMENT = 'Append-only raw data from FREG — Folkeregisteret (Norwegian national population register). '
          'Highest trust source. No phone, email, or organization field.';

DEFINE TABLE {{db}}.{{raw_schema}}.CRMI_RAW_TB_BS (
    SSN           VARCHAR(11)  NOT NULL COMMENT 'Norwegian personnummer (DDMMYYXXXCC, modulus-11)',
    FIRST_NAME    VARCHAR(100) COMMENT 'Customer given name as recorded in bank system',
    LAST_NAME     VARCHAR(100) COMMENT 'Customer family name as recorded in bank system',
    PHONE         VARCHAR(20)  COMMENT 'Customer phone number — expected +47XXXXXXXX format',
    EMAIL         VARCHAR(255) COMMENT 'Customer email address',
    RECORD_DATE   DATE         COMMENT 'Date this record was effective in BS',
    ORGANIZATION  VARCHAR(10)  COMMENT 'Business line: BANK or INS (insurance)',
    _SOURCE_FILE  VARCHAR(500) COMMENT 'Source filename for data lineage (metadata$filename)'
)
COMMENT = 'Append-only raw data from BS — Bank System. '
          'Mid-trust source. Includes phone, email, and organization (BANK/INS).';

DEFINE TABLE {{db}}.{{raw_schema}}.CRMI_RAW_TB_NICE (
    SSN           VARCHAR(11)  COMMENT 'Norwegian personnummer — nullable (~30 % of records have no SSN). '
                                       'NULL drives fuzzy-only matching and data steward queue scenarios.',
    FIRST_NAME    VARCHAR(100) COMMENT 'Customer given name as recorded in NICE CRM',
    LAST_NAME     VARCHAR(100) COMMENT 'Customer family name as recorded in NICE CRM',
    PHONE         VARCHAR(20)  COMMENT 'Customer phone number — expected +47XXXXXXXX format',
    EMAIL         VARCHAR(255) COMMENT 'Customer email address',
    RECORD_DATE   DATE         COMMENT 'Date this record was effective in NICE',
    ORGANIZATION  VARCHAR(10)  COMMENT 'Business line: BANK or INS (insurance)',
    _SOURCE_FILE  VARCHAR(500) COMMENT 'Source filename for data lineage (metadata$filename)'
)
COMMENT = 'Append-only raw data from NICE — CRM/call-centre system. '
          'Lowest trust source. SSN is nullable; ~30 % of records lack SSN, '
          'exercising fuzzy name/phone matching and data steward queue scenarios.';

-- ---------------------------------------------------------------------------
-- Address tables
-- ---------------------------------------------------------------------------

DEFINE TABLE {{db}}.{{raw_schema}}.CRMI_RAW_TB_ADDRESSES_FREG (
    SRC_ADDRESS_ID  VARCHAR(50)  NOT NULL COMMENT 'Unique address identifier from FREG',
    SRC_CUSTOMER_ID VARCHAR(50)  NOT NULL COMMENT 'FK to CRMI_RAW_TB_FREG.SSN',
    GATE            VARCHAR(255) COMMENT 'Norwegian street address including house number (e.g. Storgata 12)',
    POSTNUMMER      VARCHAR(4)   COMMENT '4-digit Norwegian postal code',
    BY              VARCHAR(100) COMMENT 'Norwegian city or municipality (by/kommune)',
    LAND            VARCHAR(5)   COMMENT 'ISO 3166-1 alpha-2 country code (default NO)',
    _SOURCE_FILE    VARCHAR(500) COMMENT 'Source filename for data lineage (metadata$filename)'
)
COMMENT = 'Append-only raw address data from FREG (Folkeregisteret). '
          'Norwegian address format: gate, 4-digit postnummer, by, land.';

DEFINE TABLE {{db}}.{{raw_schema}}.CRMI_RAW_TB_ADDRESSES_BS (
    SRC_ADDRESS_ID  VARCHAR(50)  NOT NULL COMMENT 'Unique address identifier from BS',
    SRC_CUSTOMER_ID VARCHAR(50)  NOT NULL COMMENT 'FK to CRMI_RAW_TB_BS.SSN',
    GATE            VARCHAR(255) COMMENT 'Norwegian street address including house number',
    POSTNUMMER      VARCHAR(4)   COMMENT '4-digit Norwegian postal code',
    BY              VARCHAR(100) COMMENT 'Norwegian city or municipality',
    LAND            VARCHAR(5)   COMMENT 'ISO 3166-1 alpha-2 country code (default NO)',
    _SOURCE_FILE    VARCHAR(500) COMMENT 'Source filename for data lineage (metadata$filename)'
)
COMMENT = 'Append-only raw address data from BS — Bank System. '
          'Norwegian address format: gate, 4-digit postnummer, by, land.';

DEFINE TABLE {{db}}.{{raw_schema}}.CRMI_RAW_TB_ADDRESSES_NICE (
    SRC_ADDRESS_ID  VARCHAR(50)  NOT NULL COMMENT 'Unique address identifier from NICE',
    SRC_CUSTOMER_ID VARCHAR(50)  NOT NULL COMMENT 'FK to CRMI_RAW_TB_NICE — may be SSN or '
                                                   'system-generated ID when SSN is null',
    GATE            VARCHAR(255) COMMENT 'Norwegian street address including house number',
    POSTNUMMER      VARCHAR(4)   COMMENT '4-digit Norwegian postal code',
    BY              VARCHAR(100) COMMENT 'Norwegian city or municipality',
    LAND            VARCHAR(5)   COMMENT 'ISO 3166-1 alpha-2 country code (default NO)',
    _SOURCE_FILE    VARCHAR(500) COMMENT 'Source filename for data lineage (metadata$filename)'
)
COMMENT = 'Append-only raw address data from NICE CRM. '
          'Norwegian address format: gate, 4-digit postnummer, by, land. '
          'SRC_CUSTOMER_ID is SSN when available, else a NICE-internal row key '
          '(for records without personnummer).';
