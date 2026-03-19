import streamlit as st
import time
import pandas as pd
from src.snowflake_client import get_cursor, run_query_df, execute
from src.queries import (
    ULTIMATE_PARENT_LOOKUP,
    CREATE_SCHEMA_CLONE,
    CREATE_ULT_SFDC_ACCOUNTS,
    CREATE_SFDC_ACCOUNTS,
    BILLING_TABLE,
    REVENUE_SUMMARY,
    CREATE_TASK,
    EXECUTE_TASK,
    LIST_TABLES_IN_SCHEMA,
)
from src.config import (
    TEMPLATE_SHEET_ID,
    SLIDES_TEMPLATE_ID,
    GOOGLE_DRIVE_FOLDER_ID,
    FOLDER_LINK,
    EXPECTED_TABLES,
)
from src.google_client import (
    get_gspread_client,
    get_sheets_service,
    get_slides_service,
    get_drive_service,
    copy_file,
    share_file_with_user,
)
from src.report_helpers import (
    last_month_label,
    populate_google_sheet,
    generate_slides,
)

st.set_page_config(page_title="Customer Lookup", page_icon="🔍", layout="wide")
st.title("Customer Lookup")

if "lookup_stage" not in st.session_state:
    st.session_state.lookup_stage = 0

st.subheader("Step 1: Select Customer")

try:
    name_df = run_query_df(ULTIMATE_PARENT_LOOKUP)
    name_df = name_df.sort_values(by="ULTIMATE_PARENT_SALESFORCE_ACCOUNT_NAME")
    all_names = name_df["ULTIMATE_PARENT_SALESFORCE_ACCOUNT_NAME"].tolist()
except Exception as e:
    st.error(f"Failed to load customer names: {e}")
    all_names = []

search_term = st.text_input("Search Ultimate Parent Name", placeholder="Type to search (e.g. GEICO)")
if search_term:
    filtered = [n for n in all_names if search_term.upper() in str(n).upper()]
else:
    filtered = all_names

customer_names = st.selectbox(
    "Ultimate Parent Name",
    filtered,
    index=None,
    help=f"Showing {len(filtered)} of {len(all_names)} customers",
)

with st.form("customer_lookup"):
    schema_customer_name = st.text_input("Customer Name (for schema)")
    schema_customer_name = schema_customer_name.replace(" ", "_").upper()

    submitted = st.form_submit_button("Perform Account Lookup")

    if submitted:
        if not schema_customer_name:
            st.error("Please enter a customer name")
        elif customer_names is None:
            st.error("Please select an Ultimate Parent Name above")
        else:
            st.session_state.lookup_stage = 1
            st.session_state.ult_parent = customer_names
            st.session_state.schema_name = schema_customer_name

if st.session_state.lookup_stage == 1:
    schema_name = st.session_state.schema_name
    ult_parent = st.session_state.ult_parent

    st.subheader("Step 2: Creating Schema & Looking Up Accounts")

    progress = st.progress(0, text="Cloning L3_TEMPLATE schema...")

    try:
        cs = get_cursor()

        progress.progress(0.1, text="Cloning schema...")
        cs.execute(CREATE_SCHEMA_CLONE.format(schema=schema_name))

        progress.progress(0.3, text="Creating ULT_SFDC_ACCOUNTS...")
        ult_parent_escaped = ult_parent.replace("'", "''")
        cs.execute(CREATE_ULT_SFDC_ACCOUNTS.format(schema=schema_name, ult_parent=ult_parent_escaped))

        progress.progress(0.5, text="Creating SFDC_ACCOUNTS...")
        cs.execute(CREATE_SFDC_ACCOUNTS.format(schema=schema_name))

        progress.progress(0.7, text="Creating BILLING table...")
        cs.execute(f"SELECT date_trunc('quarter', current_date())")
        current_quarter_start = cs.fetchone()[0].strftime("%Y-%m-%d")
        cs.execute(f"SELECT DATEADD('day',-1,DATE_TRUNC('month',CURRENT_DATE()))")
        end_date = cs.fetchone()[0].strftime("%Y-%m-%d")
        cs.execute(f"SELECT dateadd(year, -2, dateadd(month, -3, '{current_quarter_start}'::DATE))")
        start_date = cs.fetchone()[0].strftime("%Y-%m-%d")
        cs.execute(BILLING_TABLE.format(schema=schema_name, start_date=start_date, end_date=end_date))

        progress.progress(0.9, text="Fetching revenue summary...")
        cs.execute(REVENUE_SUMMARY.format(schema=schema_name))
        columns = [desc[0] for desc in cs.description]
        data = cs.fetchall()
        revenue_df = pd.DataFrame(data, columns=columns)

        progress.progress(1.0, text="Account lookup complete!")
        st.session_state.revenue_df = revenue_df
        st.session_state.lookup_stage = 2
        st.rerun()

    except Exception as e:
        st.error(f"Error during account lookup: {e}")

if st.session_state.get("lookup_stage", 0) >= 2:
    st.subheader("Step 3: Select Accounts & Analyses")

    revenue_df = st.session_state.revenue_df.sort_values(by="LAST_3_MONTH_REVENUE", ascending=False).reset_index(drop=True)

    sf_names = sorted(revenue_df["SF_NAME"].unique().tolist())
    bulk_select = st.multiselect("Select all accounts by SF Name", sf_names, help="Pick one or more SF Names to auto-check all their accounts")

    st.caption("Revenue filters apply within selected SF Names (or all accounts if none selected)")
    rev_col1, rev_col2, rev_col3 = st.columns(3)
    with rev_col1:
        rev_filter_5k = st.button("Filter: revenue > $5,000")
    with rev_col2:
        rev_filter_500 = st.button("Filter: revenue > $500")
    with rev_col3:
        rev_clear = st.button("Clear all selections")

    in_scope = revenue_df["SF_NAME"].isin(bulk_select) if bulk_select else pd.Series([True] * len(revenue_df))

    if rev_filter_5k:
        st.session_state.account_selections = (in_scope & (revenue_df["TOTAL_REVENUE"] > 5000)).tolist()
        st.session_state._prev_bulk = bulk_select
    elif rev_filter_500:
        st.session_state.account_selections = (in_scope & (revenue_df["TOTAL_REVENUE"] > 500)).tolist()
        st.session_state._prev_bulk = bulk_select
    elif rev_clear:
        st.session_state.account_selections = [False] * len(revenue_df)
        st.session_state._prev_bulk = bulk_select
    elif "account_selections" not in st.session_state or st.session_state.get("_prev_bulk") != bulk_select:
        st.session_state._prev_bulk = bulk_select
        if bulk_select:
            st.session_state.account_selections = in_scope.tolist()
        elif "account_selections" not in st.session_state:
            st.session_state.account_selections = [False] * len(revenue_df)

    display_df = revenue_df.copy()
    display_df.insert(0, "Select Account", st.session_state.account_selections[:len(display_df)])

    selected_count = sum(st.session_state.account_selections[:len(display_df)])
    st.caption(f"{selected_count} of {len(display_df)} accounts selected")

    edited_df = st.data_editor(
        display_df,
        column_config={"Select Account": st.column_config.CheckboxColumn("Select Account")},
        hide_index=True,
        key="account_editor",
    )
    st.session_state.account_selections = edited_df["Select Account"].tolist()

    st.markdown("**Select Analyses to Run:**")
    script_names = ["Warehouse Analysis", "Query Analysis", "Storage Analysis", "Other (Serverless + Copy)", "ROI", "Usage Context"]
    if "analysis_selections" not in st.session_state:
        st.session_state.analysis_selections = [True] * len(script_names)

    if "analysis_editor" in st.session_state:
        edits = st.session_state.analysis_editor.get("edited_rows", {})
        for row_idx, changes in edits.items():
            if "Run" in changes:
                st.session_state.analysis_selections[int(row_idx)] = changes["Run"]

    script_df = pd.DataFrame({"Script Name": script_names, "Run": st.session_state.analysis_selections})
    analysis_select = st.data_editor(
        script_df,
        column_config={"Run": st.column_config.CheckboxColumn("Run")},
        hide_index=True,
        key="analysis_editor",
    )

    user_name_input = st.text_input("Your Name (for slides attribution)", value=st.session_state.get("report_user_name", ""), key="user_name_input")
    st.session_state.report_user_name = user_name_input

    btn_col1, btn_col2, btn_col3 = st.columns(3)
    with btn_col1:
        run_analysis_btn = st.button("Run Analysis", type="primary", help="Start analysis (2-5 hours)")
    with btn_col2:
        run_analysis_sheet_btn = st.button("Run Analysis → Sheet", help="Start analysis, then generate sheet when done")
    with btn_col3:
        run_analysis_sheet_slides_btn = st.button("Run Analysis → Sheet → Slides", help="Start analysis, then generate sheet + slides when done")

    def _build_scoped_df():
        selected = edited_df[edited_df["Select Account"] == True].copy()
        if selected.empty:
            return None
        selected = selected.drop(columns=["Select Account", "TOTAL_REVENUE", "LAST_3_MONTH_REVENUE"])
        for script in script_names:
            val = analysis_select[analysis_select["Script Name"] == script]["Run"].values[0]
            selected[script.upper().replace(" ", "_").replace("(", "").replace(")", "").replace("+", "")] = val
        selected.columns = [
            "SF_ID", "SF_NAME", "ACCOUNT_ID", "LOCATOR", "ACCOUNT_NAME", "DEPLOYMENT",
            "WAREHOUSE_ANALYSIS", "QUERY_ANALYSIS", "STORAGE_ANALYSIS",
            "OTHER_ANALYSIS", "ROI_ANALYSIS", "USAGE_CONTEXT_ANALYSIS",
        ]
        return selected

    def _start_analysis(schema_name, selected):
        cs = get_cursor()
        from snowflake.connector.pandas_tools import write_pandas
        conn = cs.connection
        write_pandas(
            conn, selected, "SCOPED_ACCOUNTS",
            schema=schema_name, database="FINOPS_OUTPUTS",
            auto_create_table=True, overwrite=True,
        )
        cs.execute(CREATE_TASK.format(schema=schema_name))
        cs.execute(EXECUTE_TASK.format(schema=schema_name))

    def _check_analysis_ready(schema_name):
        tables_df = run_query_df(LIST_TABLES_IN_SCHEMA.format(schema=schema_name))
        existing = set(tables_df["TABLE_NAME"].tolist())
        ready = sum(1 for t in EXPECTED_TABLES if t in existing)
        total = len(EXPECTED_TABLES)
        missing = [t for t in EXPECTED_TABLES if t not in existing]
        return ready, total, missing

    def _generate_sheet(schema_name, customer_name, progress_bar, pct_start=0.0, pct_end=1.0):
        progress_bar.progress(pct_start, text="Generating Google Sheet...")
        gclient = get_gspread_client()
        title = f"{customer_name} - {last_month_label()} Data"
        sheet_id = copy_file(TEMPLATE_SHEET_ID, title, GOOGLE_DRIVE_FOLDER_ID)
        sheet_url = f"https://docs.google.com/spreadsheets/d/{sheet_id}/edit"
        st.session_state.sheet_id = sheet_id
        st.session_state.sheet_url = sheet_url

        cs = get_cursor()
        span = pct_end - pct_start

        def sheet_progress(pct, msg):
            progress_bar.progress(min(pct_start + pct * span, pct_end), text=f"Sheet: {msg}")

        populate_google_sheet(cs, schema_name, sheet_id, gclient, progress_callback=sheet_progress)
        return sheet_id, sheet_url

    def _share_outputs(sheet_id=None, slides_id=None, user_name="FinOps Team"):
        shared = []
        if sheet_id:
            email = share_file_with_user(sheet_id, user_name)
            if email:
                shared.append(f"Sheet shared with {email}")
        if slides_id:
            email = share_file_with_user(slides_id, user_name)
            if email:
                shared.append(f"Slides shared with {email}")
        if shared:
            st.info(" | ".join(shared))

    def _generate_slides(sheet_id, schema_name, customer_name, name, progress_bar, pct_start=0.0, pct_end=1.0):
        progress_bar.progress(pct_start, text="Generating Google Slides...")
        sheets_service = get_sheets_service()
        slides_service = get_slides_service()
        drive_service = get_drive_service()

        slides_title = f"{customer_name} - FinOps Analysis"
        slides_id = copy_file(SLIDES_TEMPLATE_ID, slides_title, GOOGLE_DRIVE_FOLDER_ID)
        slides_url = f"https://docs.google.com/presentation/d/{slides_id}/edit"
        st.session_state.slides_id = slides_id
        span = pct_end - pct_start

        def slides_progress(pct, msg):
            progress_bar.progress(min(pct_start + pct * span, pct_end), text=f"Slides: {msg}")

        generate_slides(
            slides_service, sheets_service, drive_service,
            slides_id, sheet_id, customer_name, name,
            progress_callback=slides_progress,
        )
        return slides_id, slides_url

    def _show_links(sheet_url=None, slides_url=None, schema_name=None):
        st.markdown("---")
        st.markdown("### Output Links")
        cols = st.columns(3)
        with cols[0]:
            if sheet_url:
                st.markdown(f"[Google Sheet]({sheet_url})")
        with cols[1]:
            if slides_url:
                st.markdown(f"[Google Slides]({slides_url})")
        with cols[2]:
            st.markdown(f"[Drive Folder]({FOLDER_LINK})")
        if schema_name:
            st.markdown(f"**Snowflake Schema:** `FINOPS_OUTPUTS.{schema_name}`")

    if run_analysis_btn:
        schema_name = st.session_state.schema_name
        selected = _build_scoped_df()
        if selected is None:
            st.error("Please select at least one account")
        else:
            st.info("Writing scoped accounts and starting analysis...")
            try:
                _start_analysis(schema_name, selected)
                st.success(f"Analysis started for `FINOPS_OUTPUTS.{schema_name}`. Check **Analysis Status** page to monitor. Once ready, click **Generate Sheet + Slides**.")
            except Exception as e:
                st.error(f"Error starting analysis: {e}")

    if run_analysis_sheet_btn:
        schema_name = st.session_state.schema_name
        selected = _build_scoped_df()
        if selected is None:
            st.error("Please select at least one account")
        else:
            try:
                _start_analysis(schema_name, selected)
                st.session_state.pending_pipeline = "sheet"
                st.session_state.pending_schema = schema_name
                st.session_state.pending_user_name = user_name_input.strip() if user_name_input.strip() else "FinOps Team"
                st.rerun()
            except Exception as e:
                st.error(f"Error: {e}")

    if run_analysis_sheet_slides_btn:
        schema_name = st.session_state.schema_name
        selected = _build_scoped_df()
        if selected is None:
            st.error("Please select at least one account")
        else:
            try:
                _start_analysis(schema_name, selected)
                st.session_state.pending_pipeline = "sheet_slides"
                st.session_state.pending_schema = schema_name
                st.session_state.pending_user_name = user_name_input.strip() if user_name_input.strip() else "FinOps Team"
                st.rerun()
            except Exception as e:
                st.error(f"Error: {e}")

    if st.session_state.get("pending_pipeline"):
        pending = st.session_state.pending_pipeline
        p_schema = st.session_state.pending_schema
        p_name = st.session_state.get("pending_user_name", "FinOps Team")
        p_customer = p_schema.replace("_", " ").title()

        st.markdown("---")
        pipeline_label = "Sheet" if pending == "sheet" else "Sheet + Slides"
        st.subheader(f"Pipeline: {pipeline_label} generation for `{p_schema}`")

        ready, total, missing = _check_analysis_ready(p_schema)
        if ready < total:
            st.info(f"Analysis in progress: **{ready}/{total}** tables ready.")
            if missing:
                st.caption(f"Waiting for: {', '.join(missing)}")
            status_placeholder = st.empty()
            status_placeholder.warning("Auto-checking every 15 seconds...")
            time.sleep(15)
            st.rerun()
        else:
            st.success(f"All {total} tables ready! Generating {pipeline_label.lower()}...")
            progress_bar = st.progress(0, text="Generating...")
            try:
                if pending == "sheet":
                    sheet_id, sheet_url = _generate_sheet(p_schema, p_customer, progress_bar, 0.05, 0.95)
                    progress_bar.progress(1.0, text="Done!")
                    st.success("Sheet generated!")
                    _share_outputs(sheet_id=sheet_id, user_name=p_name)
                    _show_links(sheet_url=sheet_url, schema_name=p_schema)
                else:
                    sheet_id, sheet_url = _generate_sheet(p_schema, p_customer, progress_bar, 0.05, 0.50)
                    slides_id, slides_url = _generate_slides(sheet_id, p_schema, p_customer, p_name, progress_bar, 0.50, 0.95)
                    progress_bar.progress(1.0, text="Done!")
                    st.success("Sheet + Slides generated!")
                    _share_outputs(sheet_id=sheet_id, slides_id=slides_id, user_name=p_name)
                    _show_links(sheet_url=sheet_url, slides_url=slides_url, schema_name=p_schema)
                del st.session_state["pending_pipeline"]
                del st.session_state["pending_schema"]
            except Exception as e:
                st.error(f"Error generating: {e}")
                st.exception(e)
                del st.session_state["pending_pipeline"]
                del st.session_state["pending_schema"]
