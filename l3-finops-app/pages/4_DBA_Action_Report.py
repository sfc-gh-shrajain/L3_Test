import streamlit as st
import pandas as pd
from src.snowflake_client import run_query_df, get_cursor, set_session_variables, is_running_in_sis, build_table_map, rewrite_query
from src.queries import LIST_SCHEMAS, DBA_WH_DETAIL, DBA_TOP_QUERIES, DBA_ROCKS_SUMMARY

st.set_page_config(page_title="DBA Action Report", page_icon="🔧", layout="wide")
st.title("DBA Action Report")

try:
    schemas_df = run_query_df(LIST_SCHEMAS)
    schema_options = schemas_df["SCHEMA_NAME"].tolist()
except Exception as e:
    st.error(f"Failed to load schemas: {e}")
    schema_options = []

selected_schema = st.selectbox("Customer Schema", schema_options, index=None)
customer_name = st.text_input("Customer Name", value="")

if not selected_schema:
    st.info("Select a schema to generate the DBA action report.")
    st.stop()

try:
    set_session_variables(selected_schema)
    cs = get_cursor()
except Exception as e:
    st.error(f"Failed to set session variables: {e}")
    st.stop()

_sis = is_running_in_sis()

@st.cache_data(ttl=300)
def load_data(_schema):
    set_session_variables(_schema)
    tm = build_table_map(_schema) if _sis else None
    wh_q = rewrite_query(DBA_WH_DETAIL, tm) if tm else DBA_WH_DETAIL
    tq_q = rewrite_query(DBA_TOP_QUERIES, tm) if tm else DBA_TOP_QUERIES
    wh_df = run_query_df(wh_q)
    queries_df = run_query_df(tq_q)
    try:
        rk_q = rewrite_query(DBA_ROCKS_SUMMARY, tm) if tm else DBA_ROCKS_SUMMARY
        rocks_df = run_query_df(rk_q)
    except Exception:
        rocks_df = pd.DataFrame()
    return wh_df, queries_df, rocks_df

with st.spinner("Loading analysis data..."):
    wh_df, queries_df, rocks_df = load_data(selected_schema)

if wh_df.empty:
    st.warning("No warehouse data found. Has the analysis completed?")
    st.stop()


def recommend_autosuspend(row):
    current = row["AUTO_SUSPEND"]
    idle_pct = row["IDLE_PERCENTAGE"] or 0
    if current is None:
        return "N/A"
    try:
        current = int(current)
        idle_pct = float(idle_pct)
    except (ValueError, TypeError):
        return "OK"
    if current > 300 and idle_pct > 30:
        return "60s"
    if current > 300 and idle_pct > 15:
        return "120s"
    if current > 120 and idle_pct > 20:
        return "60s"
    return "OK"


def build_rule_based_actions(wh_df):
    actions = []

    for _, row in wh_df.iterrows():
        wh = row["WAREHOUSE_NAME"]
        acct = row["ACCOUNT_NAME"]
        dep = row["DEPLOYMENT"]

        high_sizing = float(row["HIGH_SIZING_CREDIT_SAVINGS"] or 0)
        high_idle = float(row["HIGH_IDLE_TIME_CREDIT_SAVINGS"] or 0)
        high_concurrency = float(row["HIGH_CONCURRENCY_CREDIT_SAVINGS"] or 0)
        high_timeout = float(row["HIGH_TIMEOUT_CREDIT_SAVINGS"] or 0)

        if high_sizing > 0:
            detail = row["SIZING_DETAILS"] or "Review sizing"
            actions.append({
                "Warehouse": wh,
                "Account": acct,
                "Deployment": dep,
                "Category": "Resizing",
                "Action": f"Resize — {detail}",
                "Current": row["CURRENT_SIZE_AT_ANALYSIS_RUNTIME"],
                "Est. Savings (Credits)": f"{float(row['LOW_SIZING_CREDIT_SAVINGS'] or 0):,.0f} – {high_sizing:,.0f}",
                "Priority": high_sizing,
            })

        rec = recommend_autosuspend(row)
        if rec != "OK" and rec != "N/A" and high_idle > 0:
            actions.append({
                "Warehouse": wh,
                "Account": acct,
                "Deployment": dep,
                "Category": "Auto-Suspend",
                "Action": f"Change auto-suspend from {int(row['AUTO_SUSPEND'] or 0)}s to {rec}",
                "Current": f"{int(row['AUTO_SUSPEND'] or 0)}s (idle {float(row['IDLE_PERCENTAGE'] or 0):.0f}%)",
                "Est. Savings (Credits)": f"{float(row['LOW_IDLE_TIME_CREDIT_SAVINGS'] or 0):,.0f} – {high_idle:,.0f}",
                "Priority": high_idle,
            })

        if high_concurrency > 0:
            actions.append({
                "Warehouse": wh,
                "Account": acct,
                "Deployment": dep,
                "Category": "Concurrency",
                "Action": f"Adjust concurrency (current max: {row['MAX_CONCURRENCY_LEVEL']}, P95 concurrency: {row['P95_QUERY_CONCURRENCY']})",
                "Current": f"Max: {row['MAX_CONCURRENCY_LEVEL']}",
                "Est. Savings (Credits)": f"{float(row['LOW_CONCURRENCY_CREDIT_SAVINGS'] or 0):,.0f} – {high_concurrency:,.0f}",
                "Priority": high_concurrency,
            })

        if high_timeout > 0:
            actions.append({
                "Warehouse": wh,
                "Account": acct,
                "Deployment": dep,
                "Category": "Timeout",
                "Action": f"Reduce statement timeout (current: {row['TIMEOUT_HOURS']}h)",
                "Current": f"{row['TIMEOUT_HOURS']}h",
                "Est. Savings (Credits)": f"{float(row['LOW_TIMEOUT_CREDIT_SAVINGS'] or 0):,.0f} – {high_timeout:,.0f}",
                "Priority": high_timeout,
            })

    df = pd.DataFrame(actions)
    if not df.empty:
        df = df.sort_values("Priority", ascending=False).reset_index(drop=True)
        df.index = df.index + 1
    return df


def build_ai_prompt(wh_df, queries_df, rocks_df, customer_name):
    top_wh = wh_df.head(15)
    wh_summary_rows = []
    for _, r in top_wh.iterrows():
        wh_summary_rows.append(
            f"- {r['WAREHOUSE_NAME']} ({r['ACCOUNT_NAME']}/{r['DEPLOYMENT']}): "
            f"size={r['CURRENT_SIZE_AT_ANALYSIS_RUNTIME']}, credits={float(r['CREDITS_XP'] or 0):,.0f}, "
            f"auto_suspend={r['AUTO_SUSPEND']}s, idle%={float(r['IDLE_PERCENTAGE'] or 0):.0f}%, "
            f"avg_util={float(r['AVG_UTILIZATION'] or 0):.0f}%, p95_util={float(r['P95_UTILIZATION'] or 0):.0f}%, "
            f"sizing_savings={float(r['LOW_SIZING_CREDIT_SAVINGS'] or 0):,.0f}-{float(r['HIGH_SIZING_CREDIT_SAVINGS'] or 0):,.0f}, "
            f"idle_savings={float(r['LOW_IDLE_TIME_CREDIT_SAVINGS'] or 0):,.0f}-{float(r['HIGH_IDLE_TIME_CREDIT_SAVINGS'] or 0):,.0f}, "
            f"sizing_detail={r['SIZING_DETAILS']}, "
            f"efficiency={float(r['WAREHOUSE_EFFICIENCY'] or 0):.0f}%, "
            f"p95_concurrency={r['P95_QUERY_CONCURRENCY']}, max_concurrency={r['MAX_CONCURRENCY_LEVEL']}"
        )

    rocks_text = ""
    if not rocks_df.empty:
        for _, r in rocks_df.iterrows():
            rocks_text += (
                f"- {r['ROCK_CATEGORY']}/{r['ROCK']}: "
                f"${float(r['TOTAL_LOW_ANNUALIZED_DOLLAR_SAVINGS'] or 0):,.0f}-"
                f"${float(r['TOTAL_HIGH_ANNUALIZED_DOLLAR_SAVINGS'] or 0):,.0f}/yr\n"
            )

    top_q_rows = []
    for _, r in queries_df.head(10).iterrows():
        top_q_rows.append(
            f"- WH={r['EXAMPLE_WAREHOUSE_NAME']}, credits={float(r['JOB_CREDITS'] or 0):,.1f}, "
            f"runs={r['NUMQUERIES']}, error_rate={float(r['ERROR_RATE'] or 0):.1%}, "
            f"cache%={float(r['RESULT_CACHED_QUERY_PERCENTAGE'] or 0):.0f}%, "
            f"query={str(r['EXAMPLE_QUERY_SHORTENED'])[:80]}"
        )

    prompt = f"""You are a Snowflake DBA advisor. Analyze the following L3 FinOps data for customer "{customer_name or selected_schema}" and produce a concise, actionable DBA handoff report.

## Savings by Category
{rocks_text or "No rocks summary available."}

## Top 15 Warehouses (by credit spend)
{chr(10).join(wh_summary_rows)}

## Top 10 Expensive Query Patterns
{chr(10).join(top_q_rows)}

## Instructions
Write a DBA action report with these sections:
1. **Executive Summary** (2-3 sentences on total opportunity)
2. **Priority 1: Quick Wins** — actions implementable in < 1 day with minimal risk (auto-suspend changes, obvious downsizing)
3. **Priority 2: Sizing Changes** — warehouses that need resizing with specific before/after recommendations and why
4. **Priority 3: Query Optimization** — top query patterns to investigate, which warehouses they impact
5. **Priority 4: Architecture Review** — longer-term items (concurrency tuning, MCW changes, timeout policy)

For each action item, include:
- The specific warehouse name
- The exact change (e.g., "ALTER WAREHOUSE X SET AUTO_SUSPEND = 60")
- Estimated credit savings range
- Risk level (Low/Medium/High)

Be specific and actionable. Use the actual warehouse names and numbers from the data."""

    return prompt


st.markdown("---")

if not rocks_df.empty:
    st.subheader("Savings Overview")
    total_low = rocks_df["TOTAL_LOW_ANNUALIZED_DOLLAR_SAVINGS"].astype(float).sum()
    total_high = rocks_df["TOTAL_HIGH_ANNUALIZED_DOLLAR_SAVINGS"].astype(float).sum()
    total_low_cr = rocks_df["TOTAL_LOW_ANNUALIZED_CREDIT_SAVINGS"].astype(float).sum()
    total_high_cr = rocks_df["TOTAL_HIGH_ANNUALIZED_CREDIT_SAVINGS"].astype(float).sum()

    m1, m2 = st.columns(2)
    m1.metric("Annualized Dollar Savings", f"${total_low:,.0f} – ${total_high:,.0f}")
    m2.metric("Annualized Credit Savings", f"{total_low_cr:,.0f} – {total_high_cr:,.0f}")
    st.dataframe(rocks_df, use_container_width=True, hide_index=True)

st.markdown("---")

rule_tab, ai_tab = st.tabs(["A: Rule-Based Actions", "B: AI-Generated Report"])

with rule_tab:
    st.subheader("Rule-Based Action Items")
    st.caption("Deterministic recommendations based on threshold logic. Fast, no AI cost, fully reproducible.")

    actions_df = build_rule_based_actions(wh_df)
    if actions_df.empty:
        st.success("No optimization actions found — all warehouses look healthy.")
    else:
        st.markdown(f"**{len(actions_df)} action items found**")

        for category in ["Resizing", "Auto-Suspend", "Concurrency", "Timeout"]:
            cat_df = actions_df[actions_df["Category"] == category]
            if cat_df.empty:
                continue
            with st.expander(f"{category} ({len(cat_df)} items)", expanded=(category in ["Resizing", "Auto-Suspend"])):
                display_df = cat_df[["Warehouse", "Account", "Deployment", "Action", "Current", "Est. Savings (Credits)"]].copy()
                st.dataframe(display_df, use_container_width=True, hide_index=True)

        st.markdown("---")
        st.subheader("Top Expensive Queries")
        if not queries_df.empty:
            st.dataframe(
                queries_df.rename(columns={
                    "EXAMPLE_WAREHOUSE_NAME": "Warehouse",
                    "EXAMPLE_QUERY_SHORTENED": "Query Pattern",
                    "NUMQUERIES": "Runs",
                    "JOB_CREDITS": "Job Credits",
                    "ANNUALIZED_JOB_CREDITS": "Annual Credits",
                    "ERROR_RATE": "Error Rate",
                    "RESULT_CACHED_QUERY_PERCENTAGE": "Cache Hit %",
                    "ANNUALIZED_ERROR_COST": "Annual Error Cost",
                    "POTENTIAL_ANNUALIZED_SAVINGS_FROM_RESULTS_CACHE_30P": "Cache Savings (30%)",
                }),
                use_container_width=True,
                hide_index=True,
            )

        csv = actions_df.drop(columns=["Priority"]).to_csv(index=False)
        st.download_button("Download Action Items CSV", csv, "dba_action_items.csv", "text/csv")

with ai_tab:
    st.subheader("AI-Generated Report")
    st.caption("Uses Snowflake Cortex LLM to analyze the data and write a contextual DBA handoff memo.")

    if st.button("Generate AI Report", type="primary"):
        with st.spinner("Generating report via Snowflake Cortex..."):
            try:
                prompt = build_ai_prompt(wh_df, queries_df, rocks_df, customer_name)
                escaped = prompt.replace("\\", "\\\\").replace("'", "\\'")
                query = f"SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-70b', '{escaped}') AS response"
                cs = get_cursor()
                cs.execute(query)
                result = cs.fetchone()[0]
                st.markdown(result)

                st.download_button(
                    "Download AI Report",
                    result,
                    f"dba_report_{selected_schema}.md",
                    "text/markdown",
                )
            except Exception as e:
                st.error(f"AI report generation failed: {e}")
                st.caption("Ensure Cortex LLM functions are available in your account.")
