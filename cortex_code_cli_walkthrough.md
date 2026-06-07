**Cortex Code CLI**

## **Quickstart for Data Engineering Workflows**

| What this guide covers This quickstart walks through a realistic Master Data Management (MDM) use case using Cortex Code CLI. You begin inside Snowflake to discover data, compare schemas across three Norwegian banking source systems (FREG, BS, and NICE), and build a Dynamic Table chain for customer golden records using personnummer as the primary match key. You then add local business context with a reusable PRD Evaluator skill and, optionally, use the resulting data product as the foundation for a Cortex data agent. |
| :---- |

**Designed for hands-on use:** run it end to end as a lab or reuse individual prompts and patterns in your own projects.

**What This Quickstart Is For**
This quickstart is written for data engineers and analytics engineers who already have CRM-style source data in Snowflake and want a fast, realistic way to evaluate what Cortex Code CLI can do for day-to-day workflows. Rather than presenting a disconnected set of prompts, it follows a single Customer MDM storyline from discovery through operationalization.

| Audience | What you will be able to do |
| :---- | :---- |
| Data engineers and analytics engineers | Discover source tables, compare schemas across FREG, BS, and NICE, build a Dynamic Table chain that produces golden customer records per organization (BANK and INS), operationalize it with a bundled skill, and extend the workflow with a reusable PRD Evaluator skill and optional agent design. |

**Before You Begin**

**Lab environment**

| Database | MDM\_DEV |
| :---- | :---- |
| **Shared inputs** | MDM\_DEV.MDM\_RAW\_v001 (read-only) |
| **Your outputs** | MDM\_DEV.MDM\_AGG\_v001 |
| **Serving layer** | MDM\_DEV.MDM\_SRV\_v001 |
| **Warehouse** | MD\_TEST\_WH |

**Set your context before you start**

| USE WAREHOUSE MD\_TEST\_WH; USE DATABASE MDM\_DEV; USE SCHEMA MDM\_AGG\_v001; |
| :---- |

**You also need:** access to the objects used in this lab, and the SNOWFLAKE.CORTEX\_USER database role on your user (directly or via a parent role) so Cortex Code CLI can use Snowflake AI features.

**Install and connect**

If Cortex Code CLI is already installed and working for your Snowflake account, you can skip this section. Otherwise, follow the official installation instructions in Snowflake documentation and then return here for the workflow steps. The quick path is below.

| Scenario | Command |
| :---- | :---- |
| **Linux, macOS, WSL** | curl \-LsS https://ai.snowflake.com/static/cc-scripts/install.sh | sh cortex \--version |
| **Windows (PowerShell)** | irm https://ai.snowflake.com/static/cc-scripts/install.ps1 | iex cortex \--version |

Launch the CLI with **cortex**. The setup wizard will guide you through choosing or creating a Snowflake connection and validating account access. Cortex Code CLI can also reuse existing Snowflake CLI connections from \~/.snowflake/connections.toml (preferred) or \~/.snowflake/config.toml (legacy).

**Optional named connection:** cortex \-c \<your\_connection\_name\>

**Cortex Code CLI Core Concepts**

Cortex Code CLI is Snowflake's AI coding agent in the terminal. It provides an agentic shell that understands both your Snowflake environment and your local project so you can work in natural language while staying in context.

**Snowflake-aware shell**

Cortex Code CLI connects to your existing Snowflake connections and respects roles, warehouses, databases, and schemas. It uses this context to generate and refine SQL, plans, and objects against the correct environment.

**Skills (bundled and custom)**

Cortex Code organizes Snowflake workflows into skills. Bundled skills encode Snowflake best practices for areas such as Dynamic Tables, semantic views, and agents. Custom skills live with your project and capture your team's repeatable patterns, such as how to interpret PRDs and structure change plans.

**Safe, reviewable execution (modes)**

Cortex Code CLI supports execution modes that make changes explainable and controlled: you can have it plan and present multi-step work before anything runs, require explicit confirmation for impactful operations, or opt into auto-execution only in trusted environments where you are comfortable letting the agent carry out approved workflows end-to-end.

**Quickstart Path**

| Step | Demo | Outcome |
| :---- | :---- | :---- |
| **1** | **Demo 1** | Discover source tables, compare FREG/BS/NICE schemas, build a golden customer record Dynamic Table chain with org-partitioned golden records and a data steward queue, and generate an operating runbook with the Dynamic Table skill. |

---

## **Demo 1 – Start Inside Snowflake (20 min)**

Value in this section: You begin with the highest-confidence path: data that is already in Snowflake. In this demo you discover the right source tables, compare three CRM schemas, generate a Dynamic Table chain that produces trusted golden customer records, and use a bundled Dynamic Table skill to understand how those objects should be operated and monitored.

Client story: Norwegian Bank runs three source systems that all carry overlapping information about the same real-world customers: FREG (Folkeregisteret — the Norwegian national population register, highest trust), BS (Bank System, mid trust), and NICE (CRM, lowest trust). Two organizations — BANK and INS (Insurance) — each need their own golden record, but share FREG as a common trusted source. There is no single trusted view across systems — duplicates, conflicting attributes, and missing history make it impossible to answer "How many customers do we have across both organizations?" The goal is a governed MDM pipeline that uses personnummer (Norwegian SSN) as the primary match key, identifies which records belong to the same person, picks the best attribute value when sources disagree (survivorship), and produces a single golden customer record per real-world entity per organization with a transparent data quality score.

**Step 1.1 – Discover the source**
Begin with data discovery. This is a core Cortex Code CLI workflow and a natural first move when you enter a new schema.

| Prompt What tables and views are in `MDM_DEV.MDM_RAW_v001`? For each object, give me a one-line description of what it appears to contain and identify which ones are most relevant to building a Customer MDM golden record pipeline. |
| :---- |

| What to look for |
| :---- |
| • The three raw source tables: CRMI\_RAW\_TB\_FREG (Folkeregisteret), CRMI\_RAW\_TB\_BS (Bank System), CRMI\_RAW\_TB\_NICE (CRM). |
| • The three corresponding address tables: CRMI\_RAW\_TB\_ADDRESSES\_FREG/BS/NICE. |
| • A short description of each table — note that FREG has no Organization or phone/email field (it is a national register). |
| • Identification of the union view (CRMA\_AGG\_VW\_CUSTOMER\_UNION) as the harmonization point, including the FREG org-broadcast pattern. |

**Step 1.2 – Compare the three source schemas**

Once you know which tables matter, compare them and highlight differences. This gives you the shortest path to a clean normalization plan.

| Prompt Compare the columns across MDM\_DEV.MDM\_RAW\_v001.CRMI\_RAW\_TB\_FREG, CRMI\_RAW\_TB\_BS, and CRMI\_RAW\_TB\_NICE. Return: \- Equivalent fields and which are present in some sources but absent in others (for example, SSN is in FREG and BS but nullable in NICE; Organization is absent from FREG entirely) \- Fields that require type normalization (dates, phone number formats) \- The trust hierarchy across sources and how it should drive survivorship \- Differences that should remain open questions instead of becoming hidden assumptions |
| :---- |

| What to look for |
| :---- |
| • That FREG is the only source with SSN (personnummer) guaranteed present; NICE records may have NULL SSN, driving the fuzzy-only matching scenario. |
| • That FREG has no Organization or Phone/Email fields — it is a national register that feeds both BANK and INS golden records via a CROSS JOIN. |
| • That trust order is FREG > BS > NICE, with a per-field exception for Citizenship in the BANK org (FREG and BS are tied at rank 1). |
| • Open questions about how to handle records that match neither SSN nor name — these go to the data steward queue. |

**Step 1.3 – Generate the MDM Dynamic Table chain**

Convert the mapping work into a production-quality first pass. Ask Cortex Code CLI for readable SQL, explicit assumptions, and a structure you would be comfortable committing to your repo.

While this task is not overly complex, we are going to turn on Plan Mode in the CLI by holding down the keys CTRL-P to see how Cortex Code can think through complex tasks.

| Hit Terminal Keys Ctrl – P  |
| :---- |

**What is Plan Mode?**

Plan mode is one of a few different execution modes that Cortex Code CLI enables users to enter based on the task they are working on.

| Mode | Description | Use Case | Activation |
| :---- | :---- | :---- | :---- |
| Interactive | Proposes changes and asks for confirmation before running impactful operations. | Everyday work where you want to see and approve each step. | Default |
| Plan mode | Stays read-only while it thinks, then returns a structured multi-step plan and waits for your approval before executing. | Multi-step or higher-risk tasks, such as creating or updating core tables. | Press `Ctrl+P` or enter `/plan` to turn plan mode on |
| Automated (trusted environments) | Executes an agreed workflow end to end with fewer prompts, once you are comfortable with the pattern. | Trusted, non-production or tightly controlled environments where the workflow has already been validated. | Use `Shift+Tab` to move into the more automated mode your team has approved for trusted environments. |

| Prompt Use database MDM\_DEV and schema MDM\_AGG\_v001 for outputs. Create a Dynamic Table chain for customer golden records by combining the three source tables in MDM\_DEV.MDM\_RAW\_v001 (CRMI\_RAW\_TB\_FREG, CRMI\_RAW\_TB\_BS, CRMI\_RAW\_TB\_NICE). The chain should produce: 1. An enriched layer that normalizes schemas, validates personnummer (modulus-11 checksum), and resolves Norwegian nickname pairs 2. A groups layer that identifies which records belong to the same real-world customer using: SSN+Name composite exact match as the primary key (confidence 100%), fuzzy Jaro-Winkler name matching as a fallback when SSN is absent, and a data steward queue flag for records that match neither 3. A golden record layer that applies org-partitioned survivorship (separate golden records for BANK and INS, trust order FREG > BS > NICE) 4. A current-state layer with one row per golden customer per organization (latest version only) 5. A history layer that tracks all attribute changes over time (SCD Type 2 using SHA2 row hashing) Also create a data steward queue Dynamic Table that surfaces unmatched records for manual review. Use REFRESH\_MODE = FULL and TARGET\_LAG = '60 minutes'. |
| :---- |

| What to look for |
| :---- |
| • A six-DT chain (enriched, groups, golden, current, history, steward queue) with readable SQL and explainable design choices at each layer. |
| • Explicit survivorship rules: FREG=1 > BS=2 > NICE=3 for BANK; FREG=1, BS=NICE=2 tied for INS; Citizenship exception for BANK (FREG=BS=1). |
| • The FREG org-broadcast pattern: since FREG has no Organization field, each FREG record must be CROSS JOINed with BANK and INS so it feeds both org-partitioned golden records. |
| • A matching threshold with a brief rationale and explicit handling of NULL SSN records. |

When finished we can exit plan mode. Make sure to keep plan mode off. (It should turn off by choosing yes to execute these actions above.)

**Step 1.4 – Use the bundled Dynamic-Table skill**

Skills are reusable workflows that tell Cortex Code how to handle a specific Snowflake task. Instead of responding in a completely open-ended way, a skill provides:

* domain context
* expected inputs
* a defined process
* structured outputs

Each skill is packaged as a small folder with a `SKILL.md` file. That file defines what the skill is for, what information it expects, what steps it should follow, and what artifacts it should return, such as SQL, plans, checklists, or evaluation results.

**Bundled skills**

Bundled skills are Snowflake-maintained skills that ship with Cortex Code. They are prebuilt, Snowflake-native workflows designed by Snowflake's product and AI teams, so you can start from proven patterns instead of a blank prompt.

In this section, you'll use a bundled skill. Later, you'll learn how to create custom skills using the same structure so your team can codify its own workflows.

**See what skills are available**

From inside a Cortex Code session, list the skills available in your environment:

| Prompt /skill list  |
| :---- |

**Inspect the Dynamic Tables skill**

Before applying a skill to your own objects, start by asking it to explain itself:

| Prompt What does the $dynamic-tables skill do? Summarize when I should use it, what inputs it expects, and what kinds of output it returns |
| :---- |

This helps you understand the skill before you rely on it.

**Apply the skill to a real object**
Then apply it to the golden record Dynamic Table to generate a practical operating runbook.

| Prompt $dynamic-tables Analyze the Dynamic Table DT\_CUSTOMER\_GOLDEN\_FUZZY in MDM\_DEV.MDM\_AGG\_v001. Return: 1\. The recommended TARGET\_LAG choice for a golden record MDM workflow and why 2\. SQL to inspect current state, lag, and refresh history 3\. The main failure or staleness patterns to watch for in a multi-step DT chain 4\. A short best-practices checklist for operating this table well |
| :---- |

| What to look for |
| :---- |
| • A runbook you would actually keep: a couple of monitoring queries and a concise operating checklist, not generic advice. |
| • Specific guidance on how DT chain staleness propagates (a lag in an upstream DT delays all downstream DTs). |

**Step 1.5 – Save one proof query (optional)**
End Demo 1 with a lightweight proof, not an exhaustive test suite. The goal is to have one simple query you can rerun after changes and to show how the MDM pipeline consolidates records.

| Prompt Give me one concise proof query for DT\_CUSTOMER\_GOLDEN\_FUZZY in MDM\_DEV.MDM\_AGG\_v001 that shows: \- Total golden records produced \- Record counts by SOURCE\_SYSTEM \- Average data quality score (DQ\_SCORE) by source And is easy to rerun after future changes. |
| :---- |

| What to look for |
| :---- |
| • A concise query that can be reused after every change. |
| **Save this output:** sql/01\_golden\_customer\_proof.sql |

**By the end of Demo 1 you have a five-layer MDM Dynamic Table chain that produces trusted golden customer records, an operating runbook generated by a bundled skill, and a simple proof query you can rerun after each change.**

---

