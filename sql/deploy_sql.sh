#!/usr/bin/env bash
#
# Deploy the L3_TEMPLATE schema (tables + procedures) to Snowflake.
#
# Reads every .sql file under sql/tables/ then sql/procedures/ and runs it
# with `snow sql -f`. Tables are deployed before procedures so the procedures'
# references resolve. Each file contains one CREATE OR REPLACE statement.
#
# The .sql files hard-code the object schema as FINOPS.L3_TEMPLATE. This script
# rewrites that prefix on the fly to the TARGET you choose.
#
# Usage:
#   ./deploy_sql.sh TEST    # deploy to FINOPS.L3_TEMPLATE_TEST
#   ./deploy_sql.sh PROD    # deploy to FINOPS.L3_TEMPLATE
#   CONNECTION=my_conn ./deploy_sql.sh TEST
#
# Nothing is destructive beyond CREATE OR REPLACE on the objects in TARGET.
# The TARGET schema must already exist.

set -euo pipefail

# --- Config (override via env or first arg) ---
ENV="${1:-}"
if [[ "$ENV" == "TEST" ]]; then
  TARGET="FINOPS.L3_TEMPLATE_TEST"
elif [[ "$ENV" == "PROD" ]]; then
  TARGET="FINOPS.L3_TEMPLATE"
elif [[ -n "$ENV" ]]; then
  TARGET="$ENV"  # allow passing full target directly
else
  echo "Usage: $0 [TEST|PROD]"
  exit 1
fi
CONNECTION="${CONNECTION:-default}"
SOURCE_PREFIX="FINOPS.L3_TEMPLATE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Deploying to:   ${TARGET}"
echo "Connection:     ${CONNECTION}"
echo "Rewriting:      ${SOURCE_PREFIX}.  ->  ${TARGET}."
echo

deploy_dir() {
  local dir="$1"
  local label="$2"
  local count=0
  echo "=== ${label} ==="
  # Sort for stable, repeatable ordering.
  while IFS= read -r -d '' file; do
    count=$((count + 1))
    local rel="${file#"${SCRIPT_DIR}/"}"
    echo "  [${count}] ${rel}"
    # Rewrite the schema prefix and pipe the statement to snow sql.
    sed "s/${SOURCE_PREFIX}\./${TARGET}./g" "${file}" \
      | snow sql -c "${CONNECTION}" --stdin
  done < <(find "${dir}" -name '*.sql' -print0 | sort -z)
  echo "  ${count} file(s) deployed from ${label}."
  echo
}

# Tables first (procedures reference them), then procedures.
deploy_dir "${SCRIPT_DIR}/tables" "tables"
deploy_dir "${SCRIPT_DIR}/procedures" "procedures"

echo "Done. Deployed to ${TARGET}."
