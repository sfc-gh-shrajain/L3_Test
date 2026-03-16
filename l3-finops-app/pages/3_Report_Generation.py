import re
import streamlit as st
from src.snowflake_client import run_query_df, get_cursor
from src.queries import LIST_SCHEMAS
from src.config import (
    TEMPLATE_SHEET_ID,
    SLIDES_TEMPLATE_ID,
    GOOGLE_DRIVE_FOLDER_ID,
    FOLDER_LINK,
)
from src.google_client import (
    get_gspread_client,
    get_sheets_service,
    get_slides_service,
    get_drive_service,
    copy_file,
)
from src.report_helpers import (
    last_month_label,
    populate_google_sheet,
    generate_slides,
)


def extract_sheet_id(url_or_id):
    m = re.search(r"/spreadsheets/d/([a-zA-Z0-9_-]+)", url_or_id)
    if m:
        return m.group(1)
    return url_or_id.strip()


st.set_page_config(page_title="Report Generation", page_icon="📄", layout="wide")
st.title("Report Generation")

try:
    schemas_df = run_query_df(LIST_SCHEMAS)
    schema_options = schemas_df["SCHEMA_NAME"].tolist()
except Exception as e:
    st.error(f"Failed to load schemas: {e}")
    schema_options = []

selected_schema = st.selectbox("Customer Schema", schema_options, index=None)
customer_name = st.text_input("Customer Name (for report title)")
user_name = st.text_input("Your Name (for slides attribution)", value="")

st.markdown("---")

sheet_tab, slides_tab = st.tabs(["1 - Google Sheet", "2 - Google Slides"])

with sheet_tab:
    st.subheader("Generate Google Sheet")
    st.caption("Creates a copy of the template sheet and populates it with analysis data from the selected schema.")

    generate_sheet_btn = st.button("Generate Google Sheet", type="primary")

    if generate_sheet_btn:
        if not selected_schema:
            st.error("Please select a schema")
            st.stop()
        if not customer_name:
            st.error("Please enter a customer name")
            st.stop()

        progress_bar = st.progress(0, text="Starting...")

        try:
            gclient = get_gspread_client()

            progress_bar.progress(0.05, text="Copying template...")
            title = f"{customer_name} - {last_month_label()} Data"
            sheet_id = copy_file(TEMPLATE_SHEET_ID, title, GOOGLE_DRIVE_FOLDER_ID)
            sheet_url = f"https://docs.google.com/spreadsheets/d/{sheet_id}/edit"
            st.session_state.sheet_id = sheet_id
            st.session_state.sheet_url = sheet_url
            st.success(f"Created: [{title}]({sheet_url})")

            cs = get_cursor()

            def sheet_progress(pct, msg):
                progress_bar.progress(min(0.05 + pct * 0.95, 1.0), text=msg)

            populate_google_sheet(cs, selected_schema, sheet_id, gclient, progress_callback=sheet_progress)
            progress_bar.progress(1.0, text="Google Sheet complete!")

            st.markdown(f"[Open Google Sheet]({sheet_url})")
            st.markdown(f"[Output Folder]({FOLDER_LINK})")

        except Exception as e:
            st.error(f"Sheet generation failed: {e}")
            st.exception(e)

with slides_tab:
    st.subheader("Generate Google Slides")
    st.caption("Creates slides from a completed Google Sheet. Uses the sheet from Step 1 by default, or paste a sheet URL.")

    default_sheet_display = st.session_state.get("sheet_url", "")
    sheet_source = st.text_input(
        "Google Sheet URL (auto-filled from Step 1, or paste a different one)",
        value=default_sheet_display,
        key="slides_sheet_input",
    )

    generate_slides_btn = st.button("Generate Google Slides", type="primary")

    if generate_slides_btn:
        if not customer_name:
            st.error("Please enter a customer name")
            st.stop()
        if not sheet_source.strip():
            st.error("Please generate a Google Sheet first (Step 1), or paste a sheet URL")
            st.stop()

        sheet_id = extract_sheet_id(sheet_source)
        progress_bar = st.progress(0, text="Starting slides...")

        try:
            sheets_service = get_sheets_service()
            slides_service = get_slides_service()
            drive_service = get_drive_service()

            progress_bar.progress(0.05, text="Copying slides template...")
            slides_title = f"{customer_name} - FinOps Analysis"
            slides_id = copy_file(SLIDES_TEMPLATE_ID, slides_title, GOOGLE_DRIVE_FOLDER_ID)
            slides_url = f"https://docs.google.com/presentation/d/{slides_id}/edit"
            st.session_state.slides_id = slides_id
            st.success(f"Created: [{slides_title}]({slides_url})")

            def slides_progress(pct, msg):
                progress_bar.progress(min(0.05 + pct * 0.95, 1.0), text=msg)

            name = user_name.strip() if user_name.strip() else "FinOps Team"

            generate_slides(
                slides_service, sheets_service, drive_service,
                slides_id, sheet_id, customer_name, name,
                progress_callback=slides_progress,
            )

            progress_bar.progress(1.0, text="Slides complete!")
            st.markdown(f"[Open Google Slides]({slides_url})")
            st.markdown(f"[Output Folder]({FOLDER_LINK})")

        except Exception as e:
            st.error(f"Slides generation failed: {e}")
            st.exception(e)
