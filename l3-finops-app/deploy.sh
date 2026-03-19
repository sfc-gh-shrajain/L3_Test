#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# deploy.sh — Deploy L3 FinOps Streamlit app to Snowflake (SiS)
#
# Usage:
#   ./deploy.sh TEST     # deploy to FINOPS_APPS.L3_TEST
#   ./deploy.sh PROD     # deploy to FINOPS_APPS.L3_PROD
# ──────────────────────────────────────────────────────────────

ENV="${1:-}"
if [[ "$ENV" != "TEST" && "$ENV" != "PROD" ]]; then
    echo "Usage: $0 [TEST|PROD]"
    exit 1
fi

DATABASE="FINOPS_APPS"
SCHEMA="L3_${ENV}"
STAGE="L3_APP_STAGE"
APP_NAME="L3_FINOPS_APP"
WAREHOUSE="FINOPS_WH"
ROLE="SALES_MODELING_RL"
CONNECTION="default"

STAGE_PATH="@${DATABASE}.${SCHEMA}.${STAGE}/${APP_NAME}"
APP_FQN="${DATABASE}.${SCHEMA}.${APP_NAME}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "═══════════════════════════════════════════════════"
echo "  Deploying L3 FinOps App → ${APP_FQN}"
echo "  Stage: ${STAGE_PATH}"
echo "═══════════════════════════════════════════════════"

run_sql() {
    snow sql -q "$1" --connection "$CONNECTION" 2>&1
}

# ── Step 1: Upload files to stage ──────────────────────────────
echo ""
echo "Step 1: Uploading files to stage..."

run_sql "REMOVE ${STAGE_PATH};" || true

snow stage copy \
    "${SCRIPT_DIR}/streamlit_app.py" \
    "${STAGE_PATH}/" \
    --connection "$CONNECTION" --overwrite

snow stage copy \
    "${SCRIPT_DIR}/environment.yml" \
    "${STAGE_PATH}/" \
    --connection "$CONNECTION" --overwrite

snow stage copy \
    "${SCRIPT_DIR}/snowflake-corp-finops-analysis-0152d8301e98.json" \
    "${STAGE_PATH}/" \
    --connection "$CONNECTION" --overwrite

snow stage copy \
    "${SCRIPT_DIR}/src/__init__.py" \
    "${STAGE_PATH}/src/" \
    --connection "$CONNECTION" --overwrite

snow stage copy \
    "${SCRIPT_DIR}/src/config.py" \
    "${STAGE_PATH}/src/" \
    --connection "$CONNECTION" --overwrite

snow stage copy \
    "${SCRIPT_DIR}/src/snowflake_client.py" \
    "${STAGE_PATH}/src/" \
    --connection "$CONNECTION" --overwrite

snow stage copy \
    "${SCRIPT_DIR}/src/google_client.py" \
    "${STAGE_PATH}/src/" \
    --connection "$CONNECTION" --overwrite

snow stage copy \
    "${SCRIPT_DIR}/src/queries.py" \
    "${STAGE_PATH}/src/" \
    --connection "$CONNECTION" --overwrite

snow stage copy \
    "${SCRIPT_DIR}/src/report_helpers.py" \
    "${STAGE_PATH}/src/" \
    --connection "$CONNECTION" --overwrite

for page in "${SCRIPT_DIR}"/pages/*.py; do
    snow stage copy \
        "$page" \
        "${STAGE_PATH}/pages/" \
        --connection "$CONNECTION" --overwrite
done

echo "  Files uploaded."

# ── Step 2: Verify upload ──────────────────────────────────────
echo ""
echo "Step 2: Verifying staged files..."
run_sql "LIST ${STAGE_PATH}/;"

# ── Step 3: Create or replace Streamlit app ────────────────────
echo ""
echo "Step 3: Creating Streamlit app..."

run_sql "CREATE OR REPLACE STREAMLIT ${APP_FQN} FROM '${STAGE_PATH}' MAIN_FILE = 'streamlit_app.py';"

run_sql "ALTER STREAMLIT ${APP_FQN} SET QUERY_WAREHOUSE = '${WAREHOUSE}';"
run_sql "ALTER STREAMLIT ${APP_FQN} SET TITLE = 'L3 FinOps Automation (${ENV})';"

# ── Step 4: Set external access and secrets ────────────────────
echo ""
echo "Step 4: Configuring external access and secrets..."

run_sql "ALTER STREAMLIT ${APP_FQN} SET EXTERNAL_ACCESS_INTEGRATIONS = ('ALLOW_ALL_EAI');" \
    || echo "  ⚠ External access setup failed — check ALLOW_ALL_EAI permissions"

# ── Step 5: Grant access (PROD only gets wider grants) ─────────
echo ""
echo "Step 5: Setting permissions..."

run_sql "GRANT USAGE ON STREAMLIT ${APP_FQN} TO ROLE ${ROLE};"

if [[ "$ENV" == "PROD" ]]; then
    echo "  PROD: Add additional GRANT statements here for other roles."
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Deployment complete!"
echo "  App: ${APP_FQN}"
echo "  Open in Snowsight: Projects > Streamlit > ${APP_NAME}"
echo "═══════════════════════════════════════════════════"
