# L3_TEMPLATE - SQL source

Version-controlled definitions for the master `FINOPS.L3_TEMPLATE` schema in
Snowhouse. This schema is the template the L3 FinOps app clones once per
customer (see `../l3-finops-app/`) to run cost analysis.

Deployment here is deliberately simple: plain `.sql` files applied with
`snow sql -f` via `deploy.sh`. (A more advanced DCM-based setup is archived at
`../../dcm-later/` for later.)

> Status: **not yet deployed or pushed.** See `../../HANDOFF.md` at the
> migration root for the full state and next steps.

## Layout

```
sql/
├── deploy.sh                        # applies all files to a target schema
├── README.md                        # this file
├── tables/
│   ├── shared/          (2)   ACCESS_HISTORY, COST_TABLE
│   ├── query/           (4)   ATTRIBUTED_COST_QUERY_HISTORY_30D, QUERY_HISTORY_30D,
│   │                          QUERY_TIMEOUT_WASTE, REPEATED_QUERIES
│   ├── warehouse/       (6)   WAREHOUSE_CONFIGURATION, WAREHOUSE_IDLE_TIME,
│   │                          WAREHOUSE_LOAD_HISTORY, WAREHOUSE_SCORING,
│   │                          WAREHOUSE_SCORING_STAGING, WAREHOUSE_UTILIZATION
│   ├── storage/         (3)   AUTO_CLUSTER_ANALYSIS, TABLES2, TABLE_STORAGE_METRICS
│   ├── snowpipe/        (5)   COPY_HISTORY, COPY_HISTORY_QUERY, COPY_HISTORY_TABLE,
│   │                          SNOWPIPE_COPY_HISTORY, SNOWPIPE_PIPE_ANALYSIS
│   └── usage_context/   (3)   UEM, UEQ, UEW
└── procedures/
    ├── shared/          (4)   ACCESS_HISTORY, ACCOUNT_ORCHESTRATOR,
    │                          COST_TABLE, SP_BUILD_INTRA_MONTH_WH
    ├── query/           (8)
    ├── warehouse/       (11)
    ├── storage/         (7)
    ├── snowpipe/        (6)
    ├── usage_context/   (7)
    ├── roi/             (4)
    └── other/           (4)
```

**Total: 23 tables + 51 procedures = 74 files.**

Domain subfolders are for human navigation only. Every object is still
`FINOPS.L3_TEMPLATE.<NAME>` in Snowflake regardless of folder.

## How to deploy

`deploy.sh` reads every file under `tables/` (first), then `procedures/`, and
applies each with `snow sql`. It rewrites the `FINOPS.L3_TEMPLATE.` prefix on
the fly so you can target a scratch schema before the live one.

```bash
# Deploy to the default safe TEST schema (FINOPS.L3_TEMPLATE_TEST)
./deploy.sh

# Deploy to the live master (prompts for confirmation)
./deploy.sh FINOPS.L3_TEMPLATE

# Any other scratch target
TARGET=FINOPS.MY_SCRATCH ./deploy.sh

# Use a specific Snowflake CLI connection (default: "default")
CONNECTION=my_conn ./deploy.sh
```

**Prerequisites:**
- Snowflake CLI installed and a working connection (`snow connection test`).
- The target schema must already exist. For the default TEST target:
  ```sql
  CREATE SCHEMA IF NOT EXISTS FINOPS.L3_TEMPLATE_TEST;
  ```
  (Creating a schema in the FINOPS database needs the `FINOPS_ADMIN_RL` role.)
- Deploy role needs `CREATE TABLE` + `CREATE PROCEDURE` on the target schema.

Tables are always deployed before procedures so references resolve.

## How the app uses this schema

1. Analyst selects a customer in the Streamlit app.
2. App runs `CREATE SCHEMA FINOPS_OUTPUTS.<CUSTOMER>_<MMM>_<YYYY> CLONE FINOPS.L3_TEMPLATE`.
3. App writes `SCOPED_ACCOUNTS` into the clone and creates a task that calls
   `ACCOUNT_ORCHESTRATOR`, which fans out to the domain orchestrators and
   their leaf procedures.
4. App reads 17 queries from the clone to build a Google Sheet + Slides deck.

Because clones are point-in-time, deploying an update to `FINOPS.L3_TEMPLATE`
only affects **future** customer runs. Existing `FINOPS_OUTPUTS.*` schemas keep
the procedure copies they were cloned with.

## Table map

The app expects 19 tables per clone (`EXPECTED_TABLES` in
`../l3-finops-app/src/config.py`), from three sources:

- **4 declared in these files** (`tables/`): `REPEATED_QUERIES`,
  `AUTO_CLUSTER_ANALYSIS`, `ATTRIBUTED_COST_QUERY_HISTORY_30D`, `COST_TABLE`.
- **4 written by the app** via pandas `write_pandas` (not here):
  `SCOPED_ACCOUNTS`, `BILLING`, `SFDC_ACCOUNTS`, `ULT_SFDC_ACCOUNTS`.
- **11 created dynamically inside procedures** (not here): `UEQ_COMBINED`,
  `UEM_COMBINED`, `UEW_COMBINED`, `WAREHOUSE_AGG`, `ACCOUNT_STORAGE_OVERVIEW`,
  `UNUSED_ACTIVE_STORAGE`, `INACTIVE_STORAGE_LT`, `ACCOUNT_ROCKS_SAVINGS`,
  `SCOPED_ACCOUNTS_ROCKS_SUMMARY`, `CLOUD_SERVICES_ACCOUNT_AGG`,
  `CLOUD_SERVICES_QUERIES`.

## Excluded objects

Present in the source DDL, intentionally NOT here:

- **7 test/dated procedures:** `QUERY_ATTRIBUTION_30D_TEST`,
  `QUERY_HISTORY_30D_251107`, `QUERY_HISTORY_30D_251126`,
  `QUERY_HISTORY_30D_TEST`, `UEM_OLD_TEST`, `UEQ_OLD_TEST`, `UEW_OLD_TEST`.
- **1 duplicate overload:** `SNOWPIPE_PIPE_ANALYSIS(VARCHAR, VARCHAR)`. The
  1-arg version is the one `OTHER_ANALYSIS` actually calls.

## Regenerating from source

If the source DDL (`../../L3_TEMPLATE_ddl.sql`) changes:

```bash
cd /Users/shrajain/Downloads/L3_Migration
rm -rf finops-l3-app/sql/{tables,procedures}
python3 scripts/split_ddl.py
```

The splitter is idempotent - same 74 files each run. It unescapes the doubled
quotes (`""FOO""` -> `"FOO"`) from the source export.

## Notes

- `CREATE OR REPLACE` is used (not DCM's `DEFINE`). Re-running a file simply
  replaces the object.
- This approach does NOT track state or drop removed objects. If you delete a
  procedure file, you must drop it in Snowflake manually. (DCM would automate
  that - see `../../dcm-later/` when you want it.)
