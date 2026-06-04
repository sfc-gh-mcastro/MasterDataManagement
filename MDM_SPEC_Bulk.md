# Snowflake: Master Data Management (MDM)

## Marcel Däppen | Principal Solutions Engineer | Snowflake | EMEA Growth Markets

Version 2026-04-24

## **Executive Summary**

Through M\&A and other historical changes, organizations often end up running multiple systems in parallel (CRM, ERP, billing, support, etc.) that all store overlapping information about the same real‑world entities. The result is fragmented and conflicting master data: duplicates, inconsistent attributes, missing history, and no single, trusted view across channels and lines of business.

This showcase explains why we need Master Data Management (MDM), what we aim to deliver, and how we implement it using CRM (customer relationship data) as a concrete example. The centerpiece is a **golden customer record** per real‑world customer — including a linked primary address — assembled from three CRM systems into a single, trusted view with transparent logic for matching, survivorship, and data quality scoring.

## **Why Master Data Management**

### Business Problems Without MDM

Running multiple CRMs (e.g., legacy, acquired company, call center) without MDM typically leads to:

- **No single source of truth**  
  - The same customer exists multiple times across systems with different names, addresses, emails, or statuses.  
  - Nobody can answer confidently “How many customers do we have?” or “Is this one customer or three?”  
- **Poor customer experience and sales effectiveness**  
  - Sales and service agents cannot see full interaction history, open opportunities, and service issues in one place.  
  - Marketing and sales automation send duplicate or inconsistent messages to the same person.  
- **Operational inefficiency and higher cost‑to‑serve**  
  - Manual de‑duplication, spreadsheet reconciliations, and one‑off extracts to reconcile reports.  
  - Every project spends time “fixing the same data again” instead of building new capabilities.  
- **Risk and compliance exposure**  
  - Difficulty proving which customer data was used for decisions at a given point in time (missing history).  
  - Hard to implement GDPR/CCPA rights or AML/KYC controls consistently when customer identity is ambiguous.  
- **Limited value from AI & analytics**  
  - Models trained on fragmented or low‑quality customer data underperform or produce biased results.  
  - Customer 360, churn, cross‑sell, and risk models all depend on clean, unified master data.

## **Target Business Outcomes**

By introducing MDM for CRM customer data, we aim to achieve:

- **Customer 360 for sales, service, and marketing**  
  - One golden customer record (customer \+ primary address) with interaction history and a data quality score.  
  - Better targeting, fewer duplicates, higher conversion, and more relevant next‑best actions.  
- **Trustworthy reporting and regulatory submissions**  
  - Consistent customer identifiers across CRM, billing, risk, and finance.  
  - Transparent change history (SCD Type 2\) to reconstruct “what we knew when.”  
- **More efficient operations**  
  - Automated match–merge and survivorship reduce manual data cleansing.  
  - Standardized data quality scores shift effort from firefighting to continuous improvement.  
- **Stronger foundation for AI and analytics**  
  - A robust, governed customer master data layer becomes the backbone for AI use cases (personalization, credit risk, fraud detection, marketing optimization, etc.).

## **What We Mean by MDM (Scope & Concepts)**

### Scope for the CRM Showcase

As a pragmatic first step, we focus on Customer and Address master data sourced from three CRM systems with different trust levels and record counts:

**In scope**

- Customer master data – core identity and contact attributes.  
- Address master data – a single primary address per customer in this showcase.  
- Entity resolution – identifying which CRM records belong to the same real‑world customer.  
- Survivorship – deciding which attribute values win when multiple sources disagree.  
- Data quality (DQ) scoring – standardized, rule‑based 0–100 score per golden customer record.  
- Customer 360 view – serving layer providing analytics‑ready and API‑ready views.

**Out of scope (for the first iteration)**

- Additional domains (Product, Account, Household, Organization, …).  
- Stewardship UI and manual workflows (all logic is implemented as batch SQL in the showcase).  
- API integration layer and advanced governance (consent, retention) beyond basic tagging/masking.  
- Multiple addresses and complex hierarchies (N:M) – the current model is 1:1 customer–address.

### Key MDM Concepts

- **Entity resolution**  
  Identifying and grouping records that refer to the same real‑world customer across sources.  
- **Golden customer record**  
  The single authoritative master record for a customer (including its primary address) after survivorship rules are applied across all matched source records.  
- **Survivorship**  
  The ordered set of rules that determine which source value wins per attribute (e.g., completeness → source trust → recency).  
- **Data quality (DQ) score**  
  A 0–100 score per golden customer record based on field‑level and cross‑field validation rules (errors, warnings, bonuses) that quantifies how trustworthy each record is.

## **CRM Showcase: From Fragmented CRM Data to Golden Customer Records**

### Baseline Situation

In the showcase, we ingest 1,500 customer \+ address records from three CRM systems:

- **CRM\_A (Legacy, Trust 1\)** – 600 customers.  
- **CRM\_B (Acquired company, Trust 2\)** – 400 customers.  
- **CRM\_C (Call center, Trust 3\)** – 500 customers.

These are merged into **1,115 golden customer records** with 1:1 linked primary addresses, yielding a **24.4% merge rate**, a total of **272 merged customers**, and an average **DQ score of 95**, with **973 records** in the “Excellent” DQ tier.

This demonstrates that even relatively “clean” CRM landscapes can hide a significant amount of duplication and inconsistency.

### End‑to‑End Process (Business View)

The end‑to‑end CRM MDM process follows four logical steps:

1. **Union & harmonize**  
   - Standardize schemas and formats across CRM\_A/B/C into a common customer and address schema.  
   - Normalize names, casing, phone formats, and email structures.  
2. **Enrich & screen**  
   - Apply AI‑based enrichment to:  
     - Normalize nicknames to canonical names (e.g., “Bill” → “William”).  
     - Flag fake or test names for lower DQ scores.  
3. **Group (entity resolution)**  
   - Group records that represent the same real‑world customer into a common group ID using a combination of exact matches (e.g., email, phone) and similarity checks (e.g., name \+ city).  
   - Each group corresponds to one golden customer record.  
4. **Survive & score**  
   - For each attribute within a group, apply survivorship rules to choose the best value and build the golden customer record.  
   - Run DQ rules against the golden record to compute a DQ score and tier (Excellent / Good / Fair / Poor).

Snowflake’s native platform (Stages, Streams, Tasks, Tables, Dynamic Tables, Views) executes this pipeline continuously. From a business standpoint, the key idea is simple: many noisy CRM records go in; one trusted, scored golden customer record comes out, with a full change history.

## **How the Golden Customer Record Is Built**

This section describes how we decide which values end up in the golden customer record and why.

### Grouping: Deciding Which CRM Records Belong Together

**Objective:** Merge only records that truly represent the same real‑world customer, minimizing false merges while aggressively removing duplicates.

The process combines:

- **Blocking**  
  To avoid comparing every record with every other, we first create blocks based on similar attributes (for example: last‑name sound, email domain, or phone suffix). Only records in the same block are compared in detail.  
- **Deterministic rules (high confidence)**  
  - Exact email match (case‑normalized).  
  - Normalized phone match (same last digits, minimum length).  
  - Same last name \+ same date of birth (planned — requires DOB field in source data).  
- **Probabilistic rules (fuzzy matching)**  
  - High similarity of full names.  
  - Similar address (e.g., same street \+ postal code).  
  - Same email domain \+ similar first name.

Each candidate pair gets a match score based on these rules. Above a defined threshold, the records are auto‑merged into the same group; below another threshold they are rejected; in between they are considered lower‑confidence and are candidates for data stewardship in a later phase.

### Survivorship: Attribute‑Level Decision Logic

Once we have a group of records for the same customer, we decide which attribute values win.

1. **Source trust hierarchy**  
   Reflecting business reality about system reliability, the showcase uses:  
   - CRM\_A (Legacy system) – highest trust (1).  
   - CRM\_B (Acquired company) – medium trust (2).  
   - CRM\_C (Call center) – lower trust (3).  
2. **Consistent rules per attribute**  
   For each attribute, survivorship follows an ordered rule set, typically:  
   - Step 1 – **Completeness**: prefer non‑null, non‑empty, sufficiently long values.  
   - Step 2 – **Source trust**: among complete values, prefer the most trusted source (CRM\_A \> CRM\_B \> CRM\_C).  
   - Step 3 – **Recency**: if still tied, pick the most recent update (latest change timestamp).  
3. **Examples from the CRM showcase**  
   

| Attribute | Primary strategy | Fallback |
| :---- | :---- | :---- |
| First name | Non‑empty (length \> 1) → higher‑trust source → most recent | Next source |
| Last name | Non‑empty (length \> 1) → higher‑trust source → most recent | Next source |
| Email | Valid format → trusted source order (CRM\_A \> CRM\_B \> CRM\_C) → most recent | Next source |
| Phone | Valid length (\>= 7) → higher‑trust source → most recent | Next source |
| Address | Non‑null, sufficiently long street/city/postal code; country favors CRM\_A | Higher‑trust source |

   

4. **Illustrative example**  
   

| Field | CRM\_A | CRM\_B | CRM\_C | Golden record (reason) |
| :---- | :---- | :---- | :---- | :---- |
| first\_name | Bill | William | (null) | William – more complete and more recent, length \> 1 |
| last\_name | Smith | Smith | Smth | Smith – tie resolved in favor of higher‑trust CRM |
| email | [bill@acme.com](mailto:bill@acme.com) | (null) | [b@test.xyz](mailto:b@test.xyz) | [bill@acme.com](mailto:bill@acme.com) – trusted CRM\_A \+ valid format |
| phone | \+11043321819 | \+110433218 | (null) | \+11043321819 – longest valid number |

This logic is transparent and repeatable: business stakeholders can understand why a given attribute won, and data teams can adjust priorities (for example, preferring recency over trust for some attributes) without redesigning the platform.

## **Data Quality Scoring on the Golden Customer Record**

After survivorship, we run DQ rules on the golden customer record to compute a DQ score (0–100) and tier:

- **Starting point:** 100 points.  
- **Errors:** −20 points (e.g., invalid email, missing first name, invalid country code).  
- **Warnings:** −5 points (e.g., disposable email domain, suspicious phone pattern, very short street).  
- **Bonuses:** \+5 to \+10 points for high‑quality patterns (e.g., name appears in email, complete address fields).

The final score is clamped between 0 and 100 and mapped to tiers:

- 90–100: **Excellent**  
- 70–89: **Good**  
- 50–69: **Fair**  
- \<50: **Poor**

**Concrete business usage examples:**

- **Marketing:** Only customers with DQ ≥ 80 are eligible for large‑scale outbound campaigns to reduce bounce rates and complaints.  
- **Risk & compliance:** Onboarding flows may require DQ ≥ 70 before a customer can be used in KYC/AML screening without manual review.  
- **Operations:** Customers with DQ \< 50 feed a stewardship backlog so data stewards know exactly which records to fix first.

In the CRM showcase, with this logic, 973 of 1,115 golden customer records land in the “Excellent” tier, providing a strong story for stakeholders.

## **History and Lineage: Knowing “What Changed When”**

To support analytics, regulatory, and audit needs, we maintain:

- **Current golden customer records** in continuously refreshed views / Dynamic Tables.  
- **SCD Type 2 history Dynamic Tables** for customers and addresses, using declarative SHA2 row‑hash change detection via LAG() and validity ranges (VALID\_FROM, VALID\_TO, IS\_VALID). No stored procedures or tasks needed.

This gives the business:

- Full auditability of master data changes over time.  
- The ability to reconstruct regulatory reports or decisions exactly as they were at any historical point.

## **The Implementation (Technical View)**

From a technical perspective, the CRM MDM showcase is implemented entirely with native Snowflake capabilities.

### Dataflow

At a high level, the dataflow is:

- RAW tables → UNION ALL → Cortex enrichment → Match \+ group → Survivorship → Dynamic Tables \+ SCD2 history Dynamic Tables.

\-- DATAFLOW:

\--   RAW Tables → Union ALL → Cortex Enrich → Match+Group → Survive → DT \+ SCD2 DT

\--

\--   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐

\--   │ **TB\_CUSTOMER\_A**    │  │ **TB\_CUSTOMER\_B**    │  │ **TB\_CUSTOMER\_C**    │  

\--   │ (CRM\_RAW\_001)    │  │ (CRM\_RAW\_001)    │  │ (CRM\_RAW\_001)    │

\--   └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘

\--            │                     │                     │

\--            └─────────┬───────────┼─────────────────────┘

\--                      ▼

\--            ┌──────────────────────────┐

\--            │ **VW\_CUSTOMER\_UNION**        │  ← ALL records (no ROW\_NUMBER filter)

\--            │ \- Standardize columns    │     \+ file\_date from \_SOURCE\_FILE

\--            │ \- CRM\_A: first, last     │     email: LOWER(TRIM())

\--            │ \- CRM\_B: SPLIT name      │     phone: REGEXP\_REPLACE

\--            └────────────┬─────────────┘

\--                         ▼

\--            ┌──────────────────────────┐

\--            │ **DT\_CUSTOMER\_ENRICHED**     │  ← Cortex AI Enrichment (DT, materialized)

\--            │ \- canonical\_first\_name   │     CORTEX.COMPLETE nickname→formal

\--            │ \- is\_fake\_name           │     AI\_CLASSIFY real vs fake

\--            └────────────┬─────────────┘

\--                         ▼

\--            ┌──────────────────────────┐

\--            │ **VW\_CUSTOMER\_GROUPS**       │  ← Entity Resolution \+ Clustering

\--            │ Matching (CTE):          │     Uses canonical\_first\_name

\--            │ \- Email, Phone, Name     │     MATCH-D01: Email (1.0)

\--            │ \- SOUNDEX, Jaro-Winkler  │     MATCH-D02: Phone (0.95)

\--            │ Grouping:                │     MATCH-P: Probabilistic (0.70)

\--            │ \- Assign customer\_id     │     DENSE\_RANK() over cluster

\--            └────────────┬─────────────┘

\--                         ▼

\--            ┌──────────────────────────┐

\--            │ **DT\_CUSTOMER\_GOLDEN**       │  ← Survivorship per file\_date (DT)

\--            │ Survivorship:            │     FIRST\_VALUE() partitioned by

\--            │ \- first\_name: non-empty  │     (customer\_id, file\_date)

\--            │ \- email: valid \+ CRM\_A   │     Returns ALL versions

\--            │ \- phone: longest         │     DQ Score: weighted 0-100

\--            └────────────┬─────────────┘

\--                         ▼

\--       ┌─────────────────┴─────────────────┐

\--       ▼                                   ▼

\-- ┌──────────────────┐            ┌──────────────────────────────┐

\-- │ **DT\_CUSTOMER**      │            │ **DT\_CUSTOMER\_HISTORY** (DT)     │

\-- │ (Current State)  │            │ SHA2 row-hash \+ LAG()        │

\-- │ QUALIFY latest   │            │ Declarative SCD2             │

\-- │ TARGET\_LAG=1hr   │            │ valid\_from, valid\_to         │

\-- └──────────────────┘            └──────────────────────────────┘

Key components include:

- **RAW tables:** TB\_CUSTOMER\_A, TB\_CUSTOMER\_B, TB\_CUSTOMER\_C (per CRM system).  
- **Unified view:** VW\_CUSTOMER\_UNION (standardized columns, harmonized formats, file\_date from \_SOURCE\_FILE).  
- **Enrichment Dynamic Table:** CRMA\_AGG\_DT\_CUSTOMER\_ENRICHED (canonical first name via CORTEX.COMPLETE, fake‑name detection via AI\_CLASSIFY).  
- **Matching & grouping view:** CRMA\_AGG\_VW\_CUSTOMER\_GROUPS (deterministic and probabilistic matching with Jaro‑Winkler, SOUNDEX, email/phone rules; cluster assignment into customer groups).  
- **Survivorship \+ DQ Dynamic Table:** CRMA\_AGG\_DT\_CUSTOMER\_GOLDEN (attribute‑level survivorship logic and weighted DQ scoring rules).  
- **Golden customer Dynamic Tables:**  
  - CRMA\_AGG\_DT\_CUSTOMER – current golden customer records (latest only).  
  - CRMA\_AGG\_DT\_CUSTOMER\_HISTORY – SCD Type 2 history using SHA2 row‑hash to detect changes and maintain VALID\_FROM / VALID\_TO ranges.

The result is a repeatable, explainable MDM pipeline implemented with SQL, Dynamic Tables, and Cortex AI functions, without requiring a separate MDM application.

## Summary

From a business point of view, MDM is not an IT project; it is a strategic capability to:

- Establish one trusted customer across systems.  
- Improve customer experience and sales effectiveness.  
- Reduce operational and regulatory risk.  
- Unlock AI‑driven and analytics‑driven value from CRM and beyond.

The CRM showcase on Snowflake proves that we can deliver all core MDM capabilities — entity resolution, survivorship, golden customer records, data quality scoring, and full history — using native platform features, with concrete, explainable logic for how each golden customer record is constructed and governed over time.