import streamlit as st
import time
from src.snowflake_client import run_query_df
from src.queries import LIST_SCHEMAS, LIST_TABLES_IN_SCHEMA, TASK_HISTORY
from src.config import EXPECTED_TABLES

import pandas as pd

st.set_page_config(page_title="Analysis Status", page_icon="📊", layout="wide")
st.title("Analysis Status")

auto_refresh = st.toggle("Auto-refresh every 60s", value=False)

st.subheader("Customer Schemas in FINOPS_OUTPUTS")
try:
    schemas_df = run_query_df(LIST_SCHEMAS)
    selected_schema = st.selectbox(
        "Select a schema to inspect",
        schemas_df["SCHEMA_NAME"],
        index=None,
    )
except Exception as e:
    st.error(f"Failed to load schemas: {e}")
    selected_schema = None

if selected_schema:
    col1, col2 = st.columns(2)

    with col1:
        st.subheader("Tables in Schema")
        try:
            tables_df = run_query_df(LIST_TABLES_IN_SCHEMA.format(schema=selected_schema))
            existing_tables = set(tables_df["TABLE_NAME"].tolist())

            status_data = []
            for table in EXPECTED_TABLES:
                exists = table in existing_tables
                row_count = None
                if exists:
                    match = tables_df[tables_df["TABLE_NAME"] == table]
                    if not match.empty:
                        row_count = match.iloc[0]["ROW_COUNT"]
                status_data.append({
                    "Table": table,
                    "Status": "✅ Ready" if exists else "⏳ Missing",
                    "Rows": int(row_count) if pd.notna(row_count) else None,
                })

            status_df = pd.DataFrame(status_data)
            st.dataframe(status_df, width="stretch")

            ready_count = sum(1 for s in status_data if "Ready" in s["Status"])
            total_count = len(EXPECTED_TABLES)
            st.progress(ready_count / total_count, text=f"{ready_count}/{total_count} tables ready")
            if ready_count == total_count:
                st.success(f"All {total_count} expected tables are present. Analysis is complete.")
            else:
                missing = [s["Table"] for s in status_data if "Missing" in s["Status"]]
                st.warning(f"{ready_count}/{total_count} tables ready. Missing: {', '.join(missing)}")

        except Exception as e:
            st.error(f"Failed to list tables: {e}")

    with col2:
        st.subheader("Recent Task History")
        try:
            task_df = run_query_df(TASK_HISTORY.format(schema=selected_schema))
            if task_df.empty:
                st.info("No task history found for this schema.")
            else:
                st.dataframe(task_df, width="stretch")
                latest = task_df.iloc[0]
                if latest.get("STATE") == "FAILED":
                    st.error(f"Last task FAILED: {latest.get('ERROR_MESSAGE', 'unknown error')}")
                elif latest.get("STATE") == "SUCCEEDED":
                    st.success(f"Last task succeeded at {latest.get('COMPLETED_TIME')}")
                elif latest.get("STATE") in ("EXECUTING", "SCHEDULED"):
                    st.info(f"Task is currently {latest.get('STATE')}...")
        except Exception as e:
            st.warning(f"Could not retrieve task history: {e}")

    st.subheader("All Tables")
    if "tables_df" in dir() and not tables_df.empty:
        st.dataframe(tables_df, width="stretch")

if auto_refresh:
    time.sleep(60)
    st.rerun()
