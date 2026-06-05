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
| **2** | **Demo 2** | Read a local spec file, create a reusable PRD Evaluator skill, and apply repeatable updates to the MDM pipeline. |
| **3** | **Demo 3 (optional)** | Use the curated golden customer records as the foundation for a Cortex data agent and establish a simple evaluation workflow. |

---

## **Demo 1 – Start Inside Snowflake (20 min)**

Value in this section: You begin with the highest-confidence path: data that is already in Snowflake. In this demo you discover the right source tables, compare three CRM schemas, generate a Dynamic Table chain that produces trusted golden customer records, and use a bundled Dynamic Table skill to understand how those objects should be operated and monitored.

Client story: Sparebank 1 runs three source systems that all carry overlapping information about the same real-world customers: FREG (Folkeregisteret — the Norwegian national population register, highest trust), BS (Bank System, mid trust), and NICE (CRM, lowest trust). Two organizations — BANK and INS (Insurance) — each need their own golden record, but share FREG as a common trusted source. There is no single trusted view across systems — duplicates, conflicting attributes, and missing history make it impossible to answer "How many customers do we have across both organizations?" The goal is a governed MDM pipeline that uses personnummer (Norwegian SSN) as the primary match key, identifies which records belong to the same person, picks the best attribute value when sources disagree (survivorship), and produces a single golden customer record per real-world entity per organization with a transparent data quality score.

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

## **Demo 2 – Add Local Context and Productionize the Workflow (30 min)**

In the first demo, Cortex Code helped you move from natural-language instructions to SQL and an operational view of Snowflake objects. In this demo, you extend that workflow with business context from a local specification file and then turn the pattern into a reusable team asset.

**Scenario**

A new requirement arrives from the Sparebank 1 grunndata team. The base pipeline is running with FREG/BS/NICE sources and org-partitioned golden records — now the team needs three advanced POC scenarios demonstrated: a data steward workflow for records that could not be matched automatically, the ability to unmerge a previously matched golden record without redeploying the pipeline, and cross-organizational data exchange where BANK and INS can identify customers they share. A specification file (`MDM_SPEC_Bulk.md`) describes the full set of changes.

This is a common kind of request: a structured spec arrives, and it needs to be translated into a concrete, reviewable engineering plan. Rather than solving it once with a long prompt every time, you can standardize the workflow as a custom skill.

**Step 2.1 – Read the local specification**

Start by understanding the business request before you design the skill. The specification file `MDM_SPEC_Bulk.md` is in your working directory.

| Prompt Read the local file MDM\_SPEC\_Bulk.md. Summarize the changes that would extend the existing Norwegian banking MDM pipeline with the three advanced POC scenarios. Return: \- What the data steward queue scenario requires (objects, UI surface, test cases) \- What the unmerge scenario requires (override table, DT chain interaction, durable demo steps) \- What the cross-org data exchange scenario requires (survivorship rule changes, not just a JOIN view) \- Ambiguities or open questions that should be resolved before implementation |
| :---- |

| What to look for |
| :---- |
| • A clear distinction between what is already implemented and what is net-new. |
| • The three scenarios broken out as independent workstreams with their own objects and test coverage. |
| • The shape of the information your custom skill should standardize. |

**Why Create a Custom Skill Here?**

If you stop here and simply ask Cortex Code to update the Dynamic Tables, you can get a reasonable one-off result.

But the repeatable pattern is the real value:

1. read the specification file
2. extract requested changes
3. translate those changes into a Dynamic Table chain update plan
4. surface assumptions and open questions
5. propose validation queries

That is exactly the kind of workflow custom skills are meant to standardize.

**What is a Custom Skill**

A custom skill is a reusable workflow you define for Cortex Code. In practice, it is usually a small folder containing a `SKILL.md` file that tells Cortex Code:

* when to use the skill
* what inputs it expects
* what steps it should follow
* what outputs it should always return

For this demo, the goal is to create a skill that consistently turns a specification file into an engineering plan for updating a target MDM Dynamic Table chain.

**Where do custom skills live?**

Cortex Code can discover skills from multiple locations:

| Skill Type | Location | Scope |
| ----- | ----- | ----- |
| **Bundled** | Built into Cortex Code | Available by default |
| **User-level** | `~/.snowflake/cortex/skills/` or `~/.cortex/skills/` | Available across projects |
| **Project-level** | `.cortex/skills/` in your repo | Available only in that project |

**Precedence:** project-level \> user-level \> bundled

For this quickstart, use a **project skill** so anyone who clones the repo gets the same behavior.

**Step 2.2 – Scaffold a Custom Skill**

You can author the skill yourself, but Cortex Code also includes a bundled workflow to help scaffold new skills.

Start by confirming it is available:

| Prompt /skill list  |
| :---- |

Then ask the skill-development workflow to help you define the new custom skill.

| Example Prompt This seems like a repeatable workflow I will have for many specification files. Walk me through \[Skill Attached: skill-development\] for building a project skill that will help me take specification files like MDM\_SPEC\_Bulk.md and turn them into a plan for extending a target MDM Dynamic Table chain. Define: \- When to use the skill \- What inputs it expects (for example, spec\_path and target\_dt\_chain) \- The exact outputs it should always return \- Best practices for surfacing assumptions and open questions instead of guessing \- An example usage for extending the Sparebank 1 MDM pipeline with data steward and unmerge scenarios Requirements: \- Make it a project skill \- Put it under .cortex/skills/ in this demo repo \- Support markdown spec files |
| :---- |

**What this skill should standardize**

Your PRD evaluator skill should return the same categories of output every time, such as:

* requested changes to source schemas and field mappings
* matching logic updates (new primary keys, new blocking strategies)
* survivorship rule changes
* Norwegian-specific DQ rule additions
* DDL delta plan for the DT chain
* validation queries

That consistency is what makes the workflow reusable across teammates and future specification files.

**Best practices for reliable custom skills**

When designing a custom skill, keep it narrow and predictable.

* Give it one clear job
* Make the output structure repeatable
* Surface assumptions explicitly instead of silently guessing
* Keep it project-local when it depends on project conventions or objects

In this case, the job is very specific: translate a specification file into a change plan for a target MDM Dynamic Table chain.

**Step 2.3 – Run the PRD Evaluator skill**

With the custom skill in place, invoke the workflow instead of rebuilding the logic from scratch. This is the step that turns a one-time prompt into a repeatable team asset.

| Prompt Run the project skill we just made prd-to-mdm Context: \- spec\_path: MDM\_SPEC\_Bulk.md \- target\_dt\_chain: DT\_CUSTOMER\_ENRICHED\_FUZZY → DT\_CUSTOMER\_GROUPS\_FUZZY → DT\_CUSTOMER\_GOLDEN\_FUZZY → DT\_CUSTOMER\_FUZZY → DT\_CUSTOMER\_HISTORY\_FUZZY Return: 1\. Summary of the three new POC scenarios (data steward queue, unmerge, cross-org exchange) 2\. Net-new objects required for each scenario 3\. Open questions and assumptions 4\. DDL delta plan for the Dynamic Table chain extensions 5\. Validation queries that prove each scenario works |
| :---- |

| What to look for |
| :---- |
| • A consistent shape you could compare across future specification files. |
| • A delta plan another engineer could review and challenge before deployment. |
| **Save this output:** notes/02\_mdm\_change\_plan.md |

**Step 2.4 – Apply the update with Snowflake best practices**

Now use the structured output from the skill to update the Dynamic Table chain. The engineering work is driven by both platform context (existing Snowflake objects) and external business context (the local specification file).

| Prompt Extend the MDM Dynamic Table chain in MDM\_DEV.MDM\_AGG\_v001 using the change plan from MDM\_SPEC\_Bulk.md. The update should add: 1\. A data steward queue Dynamic Table (DT\_CUSTOMER\_STEWARD\_QUEUE) that surfaces records where MATCH\_STATUS = 'STEWARD\_QUEUE' — no SSN and fuzzy score below threshold 2\. An unmerge override table (TB\_UNMERGE\_OVERRIDES) that the groups DT reads via a LEFT ANTI JOIN so inserting a row causes two golden records to split on the next DT refresh 3\. A cross-org 360 view (VW\_CUSTOMER\_360\_CROSS\_ORG) that joins BANK and INS golden records on SSN to show shared customers and updated survivorship rules for Scenario 6 Return: \- The new/updated SQL objects \- Demo steps for the unmerge scenario (INSERT → DT refresh → verify split) \- Any assumptions that require engineering review \- Validation queries for all three scenarios |
| :---- |

| What to look for |
| :---- |
| • Three concrete new objects: steward queue DT, unmerge override table, and cross-org view. |
| • Durable unmerge demo steps: INSERT a row into TB\_UNMERGE\_OVERRIDES → wait for DT refresh → verify the group splits into two golden records. |
| • Cross-org view that reflects survivorship rule changes (not just a JOIN), so Scenario 6 shows golden records updating when the org-sharing agreement changes source priorities. |
| **Save this output:** sql/03\_mdm\_advanced\_scenarios.sql |

**Step 2.5 – Optional: save the handoff artifacts**

If you are treating this as a real project rather than just a lab, finish by saving the change plan, validation queries, and a short note explaining what changed and why. In a Git-backed project, these files live alongside your SQL so another engineer can pull the repo, rerun the checks locally, and see exactly how the specification was applied.

| Prompt List the artifacts I should save from this specification-driven MDM extension so another engineer can review the three new scenarios, rerun the validation queries, and reuse the PRD Evaluator skill for future specification files. |
| :---- |

| What to look for |
| :---- |
| • A concise handoff package another engineer can review and rerun. |
| **Save this output:** yes |

**At this point, the quickstart is complete for most teams: you have a curated golden customer record pipeline and a repeatable workflow for evolving it with new specification files.**

---

## **Demo 3 (Optional) – Build an Agent on Top of the Finished Data Product (30 minutes)**

Why this is optional: the quickstart is complete after Demo 2. Demo 3 is for teams that want to show what comes next: how the governed golden customer record data product you just built can support a focused Cortex data agent that answers business questions over trusted data rather than querying raw or fragmented CRM tables.

Client story: By this point you have a curated golden customer record pipeline partitioned by BANK and INS, a data steward queue, and a cross-org 360 view. That is the right moment to talk about agents, because you can keep the AI experience grounded in trusted, well-modeled Norwegian banking data with transparent data quality scores — rather than sending an agent loose over raw FREG/BS/NICE source tables.

**Step 3.1 – Define the agent use case**

Keep the first pass narrow and grounded in the data product you built. The goal is to make the agent credible, not broad.

| Prompt Help me define a Cortex data agent on top of DT\_CUSTOMER\_FUZZY in MDM\_DEV.MDM\_AGG\_v001. Suggest: \- The primary audience (for example, data stewards, compliance, banking operations) \- The top five business questions the agent should answer — include questions that span BANK and INS organizations, and questions about the data steward queue \- Guardrails that keep the agent grounded in the curated golden records rather than raw FREG/BS/NICE source tables \- Any semantic descriptions that would improve answer quality for Norwegian banking context |
| :---- |

**Step 3.2 – Create a semantic view over the golden records**

Create a semantic view that exposes business-friendly dimensions and measures. This is the object the agent will rely on for most of its answers.

| Prompt Let's start by building the semantic model using the $semantic-view Create a semantic view called SV\_CUSTOMER\_360 over MDM\_DEV.MDM\_AGG\_v001.DT\_CUSTOMER\_FUZZY. It should support natural language questions like: \- "How many unique golden customer records do we have in BANK vs INS?" \- "What is the average data quality score by source system (FREG / BS / NICE)?" \- "Which customers appear in both BANK and INS — use the cross-org view" \- "How many records are currently in the data steward queue waiting for manual review?" \- "Show me customers with a DQ score below 60 in the INS organization" Return: \- A complete semantic view definition that clearly names business measures and dimensions. \- Any assumptions about grain (one row per golden customer per organization), the golden record identifier, and how ORGANIZATION is modeled as a dimension. |
| :---- |

| What to look for |
| :---- |
| • A semantic view definition with clear business measures, dimensions, and assumptions. |
| • Correct grain: one row per golden customer (latest version only). |

**Step 3.3 – Create a Cortex agent on the semantic view**

Now create a Cortex data agent that uses the semantic view to answer natural-language questions. Keep the agent grounded in SV\_CUSTOMER\_360 and make its answers verifiable.

| Prompt $cortex-agent Create an agent named CUSTOMER\_360\_ASSISTANT. The agent should: \- Prefer SV\_CUSTOMER\_360 as its primary data source. \- Always respond with three parts: (1) the final answer, (2) the SQL used, and (3) any assumptions about grain or filters. \- Ask a clarifying question if the requested metric or time grain is ambiguous. \- Never query raw FREG/BS/NICE source tables directly — always use the golden record layer or the cross-org 360 view. Return a configuration I can save alongside my project files. |
| :---- |

**Step 3.4 – Evaluate Agent Semantic View**

With the agent created, let's dive deeper into how we can improve this agent. We can start by validating our semantic view and suggesting improvements.

| Prompt Help me audit my Semantic View SV\_CUSTOMER\_360 for best practices and provide suggestions |
| :---- |

| What to look for |
| :---- |
| • An evaluation of the semantic view against MDM-specific best practices (grain clarity, DQ score as a measure, source system as a dimension). |

**Step 3.5 – Cortex Agent Skills and Workflows From Here**
Take a deeper look at the skills and workflow that exist in cortex-agent and semantic-view. Here we can see how many teams take the next step in iteration on their agents. From taking the results of their evaluation datasets or user feedback to suggest iterations, performing tests of their verified queries on their semantic models, or auditing their semantic models for best practices.

**What You Should Take Away**
The core pattern is simple: pick one concrete object, ask Cortex Code for one concrete artifact, and keep the result in the project. In Demo 1, that means a five-layer MDM Dynamic Table chain, a small runbook from a bundled skill, and a single proof query you can rerun after every change. In Demo 2, it means treating the specification file and its evaluator as part of the same data product, with a custom skill that turns a business requirements document into a structured, reviewable change plan for extending the pipeline with advanced scenarios (data steward queue, unmerge, cross-org exchange). By the time you reach the optional agent design in Demo 3, you can see how bundled skills and custom skills together create a path from disciplined data engineering to a credible AI experience built on trusted, governed customer data.
