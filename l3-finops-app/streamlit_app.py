import streamlit as st

st.set_page_config(page_title="L3 FinOps Automation", page_icon="❄️", layout="wide")

st.title("L3 FinOps Automation")
st.markdown("""
**Unified local tool for L3 customer analysis and report generation.**

Use the sidebar to navigate between pages:

1. **Customer Lookup** - Select customer, create schema, kick off analysis
2. **Analysis Status** - Monitor analysis progress and table availability
3. **Report Generation** - Generate Google Sheets + Slides reports
""")

st.info("Snowflake connection uses browser-based SSO. A browser window will open on first connection.")
