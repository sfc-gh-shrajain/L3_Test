# L3 FinOps Automation App

Unified local Streamlit app consolidating VE_L3_AUTOMATION (Snowsight Streamlit) and finops_l3_lite (Snowsight Notebook) into a single debuggable local tool.

## Setup

1. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

2. Copy your Google service account credentials file to:
   ```
   credentials/snowflake-corp-finops-analysis-0152d8301e98.json
   ```

3. Run the app:
   ```bash
   streamlit run streamlit_app.py
   ```

   A browser window will open for Snowflake SSO authentication on first run.

## Pages

| Page | What it does |
|------|-------------|
| **Customer Lookup** | Select customer by Ultimate Parent, create schema in `FINOPS_OUTPUTS`, kick off analysis via `ACCOUNT_ORCHESTRATOR` |
| **Analysis Status** | Monitor which analysis tables exist, check task history |
| **Report Generation** | Generate Google Sheet + Google Slides reports from analysis results |

## Snowflake Connection

Uses `externalbrowser` authenticator (SSO via browser). Connection details are in `src/config.py`.

## Important: Procedure Safety

The stored procedures in `FINOPS.L3_TEMPLATE` are production objects. This app only **calls** them — it never modifies their definitions. See `AGENTS.md` for AI assistant rules.
