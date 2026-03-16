# AGENTS.md — Instructions for AI coding assistants (CoCo, Copilot, etc.)

## CRITICAL: Read-Only Procedures

The stored procedures in `FINOPS.L3_TEMPLATE` are **PRODUCTION objects** shared across the FinOps team.

**NEVER** generate or execute any of the following against `FINOPS.L3_TEMPLATE`:
- `ALTER PROCEDURE`
- `CREATE OR REPLACE PROCEDURE`
- `DROP PROCEDURE`
- Any DDL that modifies procedure definitions

**ONLY** use `CALL` statements to invoke procedures. Never modify them.

## Project Structure

- `src/queries.py` — All SQL queries as constants. These mirror the notebook queries.
- `src/snowflake_client.py` — Snowflake connection via `externalbrowser` auth.
- `src/report_helpers.py` — Google Sheet population and Slides generation logic.
- `pages/` — Streamlit multi-page app pages.

## Running the App

```bash
pip install -r requirements.txt
streamlit run streamlit_app.py
```

## Lint / Typecheck

No lint/typecheck configured yet.
