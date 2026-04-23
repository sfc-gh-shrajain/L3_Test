# L3 FinOps Automation App

## What Does This App Do?

The L3 FinOps Automation App is an internal Snowflake tool for the FinOps Value Advisory team. It automates the process of analyzing a customer's Snowflake usage, identifying cost-saving opportunities (called **ROCKS**), and generating a pre-populated Google Sheet and slide deck — ready for a customer presentation.

**Before this app:** analysts manually ran SQL scripts, copied data into spreadsheets, and built slides by hand. This took hours per customer.

**With this app:** select a customer, click a button, and the sheet + slides are ready in ~2–5 hours (mostly compute time in the background).

---

## Business Goal

For each enterprise Snowflake customer, the FinOps team:
1. Analyzes how the customer spends Snowflake credits (compute, storage, queries, warehouses)
2. Identifies optimization opportunities — **ROCKS** (Revenue Optimization, Cost, and Key Savings)
3. Quantifies the savings as a Low/High dollar range
4. Presents findings in a standardized deck used for executive conversations and contract renewals

This app removes all the manual work from steps 1–3 and automates output generation for step 4.

---

## App Structure

```
l3-finops-app/
├── streamlit_app.py              # Landing page
├── pages/
│   ├── 1_Customer_Lookup.py      # Main workflow: select customer → run analysis → generate outputs
│   ├── 2_Analysis_Status.py      # Monitor background analysis progress
│   ├── 3_Report_Generation.py    # Standalone: generate Sheet/Slides from a completed schema
│   └── 4_DBA_Action_Report.py    # DBA-focused view of warehouse + query recommendations
├── src/
│   ├── queries.py                # All SQL queries (no business logic, just SQL strings)
│   ├── config.py                 # Constants: Google IDs, expected tables, session variables
│   ├── snowflake_client.py       # Snowflake connection + query helpers
│   ├── google_client.py          # Google Drive/Sheets/Slides API auth + helpers
│   └── report_helpers.py         # Logic for populating sheets and updating slides
├── deploy.sh                     # Deploy to Snowflake SiS (Streamlit in Snowflake)
└── environment.yml               # Python package dependencies
```

---

## Complete App Workflow

### Step 1 — Customer Lookup (`1_Customer_Lookup.py`)

**Select a customer** from the Ultimate Parent dropdown (loaded from `snowhouse.sales.account`).

**What happens when you click "Perform Account Lookup":**

1. **Schema is created** in `FINOPS_OUTPUTS` (e.g. `FINOPS_OUTPUTS.ACME_APR_2026`) by cloning the `FINOPS.L3_TEMPLATE` schema — this template contains all the stored procedures and views the analysis needs.
2. **Account tables are built:**
   - `ULT_SFDC_ACCOUNTS` — all Salesforce accounts under the selected ultimate parent
   - `SFDC_ACCOUNTS` — joins to Snowflake account IDs and deployment info
   - `BILLING` — 2+ years of monthly revenue/credit data per account
3. **Revenue summary is returned** — a table showing each account's Snowflake spend, used to select which accounts to analyze.

> **Key protection:** This step uses `@st.cache_resource`, meaning it only ever runs **once** per `(schema_name, customer)` combination — even if the page rerenders. This prevents accidental schema re-creation mid-flight, which was the root cause of data duplication bugs.

---

### Step 2 — Select Accounts & Start Analysis

You see a table of all accounts under the customer with their last 3-month revenue. You:
- **Check the accounts** you want to include (can filter by revenue threshold)
- **Choose which analyses to run** (Warehouse, Query, Storage, Other, ROI, Usage Context)
- **Enter your name** (appears on the slides)
- Click one of three buttons:
  - **Run Analysis** — starts background compute only
  - **Run Analysis → Sheet** — starts compute, auto-generates Sheet when done
  - **Run Analysis → Sheet → Slides** — starts compute, auto-generates both when done

**What happens when analysis starts:**

1. Your selected accounts are written to `FINOPS_OUTPUTS.{schema}.SCOPED_ACCOUNTS` as a table (this tells the procedure which accounts and analyses to run).
2. A Snowflake Task `ACCOUNT_REFRESH` is created and immediately executed:
   ```sql
   CREATE OR REPLACE TASK FINOPS_OUTPUTS.{schema}.ACCOUNT_REFRESH
       WAREHOUSE = FINOPS_WH
       SCHEDULE = '60 MINUTES'
       ALLOW_OVERLAPPING_EXECUTION = FALSE
       AS CALL FINOPS_OUTPUTS.{schema}.ACCOUNT_ORCHESTRATOR('{schema}')
   ```
3. The task calls `ACCOUNT_ORCHESTRATOR`, a stored procedure that runs all selected analyses and populates 19 output tables (see table list below).
4. If the first run doesn't finish within 60 minutes (e.g. very large customers), the task auto-retries. `ALLOW_OVERLAPPING_EXECUTION = FALSE` ensures only one run is active at a time.
5. Once all tables are ready, the task is **suspended** automatically to stop unnecessary reruns.

---

### Step 3 — Monitor Progress (`2_Analysis_Status.py`)

Select any schema from the dropdown to see:
- Which of the 19 expected tables exist (✅ Ready / ⏳ Missing)
- Row count for each table
- Recent task execution history (SUCCEEDED / FAILED / EXECUTING)
- Auto-refresh toggle (every 60 seconds)

---

### Step 4 — Generate Outputs

When all tables are ready (automatically if you used "→ Sheet" or "→ Sheet → Slides", or manually via `3_Report_Generation.py`):

**Google Sheet generation:**
1. Copies the master template sheet (`TEMPLATE_SHEET_ID` in `config.py`) into the shared Drive folder
2. Runs 17 SQL queries against the customer's schema (see Query Reference below)
3. Writes each query result into the corresponding worksheet tab

**Google Slides generation:**
1. Copies the master slides template (`SLIDES_TEMPLATE_ID`) into Drive
2. Replaces text placeholders (`<COMPANY NAME>`, `<MONTH, YEAR>`, etc.)
3. Swaps charts on 10+ slides by pulling updated charts from the Google Sheet
4. Updates data tables on slides (Quarterly Spend, UEM, Top Tenants, ROCKS Summary, etc.)
5. Returns a direct link to the finished deck

---

## Key Snowflake Resources

### Source Tables (read-only, never modified)

| Table | Database | What It Contains |
|---|---|---|
| `sales.account` | `snowhouse` | Salesforce account hierarchy (ultimate parent → child) |
| `SNOWFLAKE_ACCOUNT_REVENUE_LONG` | `finance.customer` | Daily revenue per account — source of all billing data |
| `PRICING_DAILY` | `finance.customer` | Contract pricing: credit rates, storage rates, discounts |
| `salesforce_snowflake_mapping` | `finance.customer` | Maps Salesforce account IDs → Snowflake account IDs |
| `ACCOUNT_EXTENDED_PROPERTIES_ETL_V` | `snowhouse_import.prod` | Account metadata: service level, deployment |
| `A360_USE_CASES` | `sales.sales_bi` | Active Salesforce use cases in flight for the customer |

### Customer Schema (created per customer, in `FINOPS_OUTPUTS.{schema}`)

**Setup tables** (created by the app on account lookup):

| Table | How Created | Contents |
|---|---|---|
| `ULT_SFDC_ACCOUNTS` | `CREATE_ULT_SFDC_ACCOUNTS` query | All SF accounts under the ultimate parent |
| `SFDC_ACCOUNTS` | `CREATE_SFDC_ACCOUNTS` query | Scoped accounts with Snowflake IDs |
| `BILLING` | `BILLING_TABLE` query | 2+ years monthly revenue/credits/storage |
| `SCOPED_ACCOUNTS` | Written by app (pandas `write_pandas`) | User-selected accounts + which analyses to run |

**Analysis output tables** (created by `ACCOUNT_ORCHESTRATOR` stored procedure):

| Table | Contents | Used In |
|---|---|---|
| `WAREHOUSE_CREDITS` | Credits per warehouse per month (base grain) | `WAREHOUSE_AGG` |
| `WAREHOUSE_AGG` | Warehouse-level analysis: sizing, utilization, idle time, savings estimates | Sheet tab 6-WH, DBA Report |
| `UEQ_COMBINED` | Usage Efficiency metrics by quarter | Sheet tab 4-UEQ |
| `UEM_COMBINED` | Usage Efficiency metrics by month | Sheet tab 5-UEM |
| `UEW_COMBINED` | Usage Efficiency metrics by warehouse | Sheet tab 21-UEW |
| `ACCOUNT_STORAGE_OVERVIEW` | Storage breakdown: active/time-travel/failsafe/inactive | Sheet tab 7-ST_T |
| `UNUSED_ACTIVE_STORAGE` | Tables with active storage but no recent queries | Sheet tab 8-ST_A |
| `INACTIVE_STORAGE_LT` | Tables with high inactive/churn storage | Sheet tab 9-ST_I |
| `REPEATED_QUERIES` | Top repeated query patterns: credits, errors, cache rate | Sheet tab 10-Repeated Queries |
| `ACCOUNT_ROCKS_SAVINGS` | Per-account, per-ROCK savings (Low/High credit + dollar) | Sheet tab 1-Adjustments |
| `SCOPED_ACCOUNTS_ROCKS_SUMMARY` | Rolled-up ROCKS totals by category | Sheet tab 20-ROCKS, Slides |
| `AUTO_CLUSTER_ANALYSIS` | Auto-clustering credit waste by table | Sheet tab 11-AC |
| `CLOUD_SERVICES_ACCOUNT_AGG` | Cloud services credit usage by account | Sheet tab 13-CloudServices |
| `CLOUD_SERVICES_QUERIES` | Top queries driving cloud services charges | Sheet tab 14-Cloud Services Queries |
| `ATTRIBUTED_COST_QUERY_HISTORY_30D` | Last 30 days query history with attributed cost | DBA Report |
| `COST_TABLE` | Normalized cost table for ROI calculations | Internal |

---

## Key Queries Reference

| Query Constant | Sheet Tab | What It Fetches |
|---|---|---|
| `ULTIMATE_PARENT_LOOKUP` | (dropdown) | All customers with active Snowflake accounts from Salesforce |
| `BILLING_TABLE` | (setup) | 2+ years of daily revenue rolled up to monthly per account |
| `REVENUE_SUMMARY` | (setup) | Per-account total + last-3-month revenue for account selection UI |
| `USE_CASES_QUERY_0` | 0-Use Cases | Active Salesforce use cases with go-live dates |
| `ADJUSTMENTS_QUERY_1` | 1-Adjustments | Per-account ROCKS savings with Low/High ranges |
| `SCOPED_ACCOUNTS_QUERY_2` | 2-Scoped Accounts | Which accounts were included and which analyses ran |
| `BILL_QUERY_3` | 3-BILL | Full billing detail: revenue, credits, storage, pricing |
| `UEQ_QUERY_4` | 4-UEQ | Quarterly efficiency metrics (Cr/1000 jobs, Cr/TB scanned) |
| `UEM_QUERY_5` | 5-UEM | Monthly efficiency metrics |
| `WH_QUERY_6` | 6-WH | Warehouse detail: utilization, idle %, sizing savings |
| `STORAGE_QUERY_7` | 7-ST_T | Account-level storage totals |
| `UNUSED_ACTIVE_STORAGE_QUERY_8` | 8-ST_A | Tables with active bytes but zero query activity |
| `INACTIVE_STORAGE_QUERY_9` | 9-ST_I | Tables with high inactive/failsafe storage |
| `REPEATED_QUERIES_10` | 10-Repeated Queries | Most expensive repeated query patterns |
| `AC_QUERY_11` | 11-AC | Auto-clustering tables with non-zero recluster activity |
| `AUTO_SUSPEND_QUERY_12` | 12-Auto Suspend | Warehouse idle credit breakdown by auto-suspend setting |
| `CLOUD_SERVICES_QUERY_13` | 13-CloudServices | Cloud services credit categories per account |
| `CLOUD_SERVICES_QUERIES_QUERY_14` | 14-Cloud Services Queries | Top 25 queries driving cloud services costs |
| `ROCKS_QUERY_20` | 20-ROCKS | Rolled-up ROCKS savings summary |
| `UEW_QUERY_21` | 21-UEW | Per-warehouse efficiency metrics |

---

## How to Deploy

### Deploy to TEST
```bash
cd l3-finops-app
bash deploy.sh TEST
```

### Deploy to PROD
```bash
cd l3-finops-app
bash deploy.sh PROD
```

Deploy script does: removes old stage files → uploads all source files → `CREATE OR REPLACE STREAMLIT` → sets warehouse/title/external access → grants usage to `FINOPS_VALUE_ADVISORY_RL`.

**Apps:**
- TEST: `FINOPS_APPS.L3_TEST.L3_FINOPS_APP`
- PROD: `FINOPS_APPS.L3_PROD.L3_FINOPS_APP`

Access in Snowsight: **Projects → Streamlit → L3_FINOPS_APP**

---

## How to Update or Iterate

### Change a SQL query
Edit the relevant constant in `src/queries.py`. The query name maps directly to a Sheet tab via `QUERY_TO_WORKSHEET` at the bottom of that file.

Example — to add a column to the warehouse output:
1. Edit `WH_QUERY_6` in `queries.py`
2. Make sure the column exists in `WAREHOUSE_AGG` (if not, update the stored procedure in Snowflake)
3. Deploy: `bash deploy.sh TEST`, test, then `bash deploy.sh PROD`

### Add a new Sheet tab
1. Add the new query constant to `queries.py`
2. Add it to the `query_map` dict in `report_helpers.py` → `populate_google_sheet()`
3. Add `("YOUR_QUERY_CONST", "Tab Name")` to `QUERY_TO_WORKSHEET` in `queries.py`
4. Add the new tab to the Google Sheets template manually

### Add a new expected analysis table
1. Update `EXPECTED_TABLES` in `src/config.py`
2. The Analysis Status page and the pipeline auto-wait logic will pick it up automatically

### Add a new Slides update
Edit `generate_slides()` in `src/report_helpers.py`. Each slide is updated by:
- `replace_text_placeholders()` — replaces `<PLACEHOLDER>` text in slides
- `replace_chart_on_slide()` — swaps a chart by matching chart title in the Sheet
- `update_table_on_slide()` — writes cell values from a Sheet range into a Slides table

Match slides by index (0-based). Slide 5 = index 4.

### Update the Google template files
The template IDs are in `src/config.py`:
- `TEMPLATE_SHEET_ID` — the master Google Sheet
- `SLIDES_TEMPLATE_ID` — the master Google Slides deck

To update: edit the template directly in Google Drive. The app always copies from these IDs at report generation time, so changes take effect immediately on the next run.

### Change which analyses are available
Edit the `script_names` list in `1_Customer_Lookup.py` and the column mapping in `_build_scoped_df()`. The `SCOPED_ACCOUNTS` table drives which analyses the stored procedure runs.

---

## Known Issues & Data Notes

### ROCKS savings inflation
If `WAREHOUSE_AGG` has far more rows than `WAREHOUSE_CREDITS`, the schema was built with an older stored procedure that inserted duplicate rows into sub-tables. This causes a fan-out join (up to 64×), inflating all savings percentages. **Fix:** drop and regenerate the schema using the app with a fresh schema name.

### Inovalon-type issue (warehouse recreation)
If a warehouse is deleted and recreated many times in a month, it generates multiple `WAREHOUSE_ID`s for the same logical warehouse. Each ID appears as a separate row in `WAREHOUSE_CREDITS`, causing savings to be summed multiple times. This is a data quality issue in the source, not a bug in the app.

### Large customers (e.g. >100 accounts)
`ATTRIBUTED_COST_QUERY_HISTORY_30D` can take 1–3 hours to build for large accounts (hundreds of millions of query history rows). The task auto-retries every 60 minutes if not finished. Check **Analysis Status** → Task History to monitor.

---

## Local Development

The app runs locally against Snowflake using `externalbrowser` auth. It is also deployed as **Streamlit in Snowflake (SiS)** where it uses the session's built-in credentials.

```bash
# Install dependencies
pip install -r requirements.txt  # or: conda env create -f environment.yml

# Run locally
streamlit run streamlit_app.py
```

The `snowflake_client.py` auto-detects whether it is running in SiS or locally and adjusts the connection method accordingly. Locally, queries use session variables (`SET $SCHEMA_NAME = ...`). In SiS, they use a `build_table_map()` approach to rewrite `identifier($TABLE)` references.
