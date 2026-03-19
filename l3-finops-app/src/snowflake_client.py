import os
import re
import pandas as pd
import streamlit as st
from src.config import SNOWFLAKE_ROLE, SNOWFLAKE_WAREHOUSE


def is_running_in_sis():
    try:
        import _snowflake  # noqa: F401
        return True
    except ImportError:
        pass
    if os.getenv("SNOWFLAKE_HOST"):
        return True
    if os.getenv("SNOWPARK_RUNTIME") == "snowpark":
        return True
    return False


@st.cache_resource
def get_connection():
    if is_running_in_sis():
        try:
            conn = st.connection("snowflake")
            session = conn.session()
            try:
                session.sql("USE SECONDARY ROLES ALL").collect()
            except Exception:
                pass
            try:
                session.sql(f"USE WAREHOUSE {SNOWFLAKE_WAREHOUSE}").collect()
            except Exception:
                pass
            return conn.raw_connection
        except Exception:
            from snowflake.snowpark.context import get_active_session
            session = get_active_session()
            try:
                session.sql("USE SECONDARY ROLES ALL").collect()
            except Exception:
                pass
            try:
                session.sql(f"USE WAREHOUSE {SNOWFLAKE_WAREHOUSE}").collect()
            except Exception:
                pass
            return session._conn._conn
    else:
        import snowflake.connector
        from src.config import SNOWFLAKE_USER, SNOWFLAKE_ACCOUNT
        conn = snowflake.connector.connect(
            user=SNOWFLAKE_USER,
            account=SNOWFLAKE_ACCOUNT,
            authenticator="externalbrowser",
        )
        cs = conn.cursor()
        cs.execute(f"USE ROLE {SNOWFLAKE_ROLE}")
        cs.execute("USE SECONDARY ROLE ALL")
        cs.execute(f"USE WAREHOUSE {SNOWFLAKE_WAREHOUSE}")
        cs.execute("ALTER SESSION SET TIMEZONE = 'UTC'")
        return conn


def get_cursor():
    conn = get_connection()
    return conn.cursor()


def run_query(query):
    cs = get_cursor()
    cs.execute(query)
    return cs


def run_query_df(query):
    cs = get_cursor()
    cs.execute(query)
    columns = [desc[0] for desc in cs.description]
    data = cs.fetchall()
    return pd.DataFrame(data, columns=columns)


def execute(statement):
    cs = get_cursor()
    cs.execute(statement)
    return cs


def build_table_map(schema_name):
    schema_fqn = f"FINOPS_OUTPUTS.{schema_name}"
    return {
        "SCHEMA_NAME": schema_name,
        "SCHEMA": schema_fqn,
        "ACCOUNT_ROCKS_SAVINGS": f"{schema_fqn}.ACCOUNT_ROCKS_SAVINGS",
        "SCOPED_ACCOUNTS": f"{schema_fqn}.SCOPED_ACCOUNTS",
        "BILLING": f"{schema_fqn}.BILLING",
        "UEQ": f"{schema_fqn}.UEQ_COMBINED",
        "UEM": f"{schema_fqn}.UEM_COMBINED",
        "WAREHOUSE_AGG": f"{schema_fqn}.WAREHOUSE_AGG",
        "ACCOUNT_STORAGE_OVERVIEW": f"{schema_fqn}.ACCOUNT_STORAGE_OVERVIEW",
        "UNUSED_STORAGE": f"{schema_fqn}.UNUSED_ACTIVE_STORAGE",
        "INACTIVE_STORAGE": f"{schema_fqn}.INACTIVE_STORAGE_LT",
        "REPEATED_QUERIES": f"{schema_fqn}.REPEATED_QUERIES",
        "ROCKS_SUMMARY": f"{schema_fqn}.SCOPED_ACCOUNTS_ROCKS_SUMMARY",
        "UEW": f"{schema_fqn}.UEW_COMBINED",
        "AUTO_CLUSTER": f"{schema_fqn}.AUTO_CLUSTER_ANALYSIS",
        "ATTRIBUTED_QUERIES": f"{schema_fqn}.ATTRIBUTED_COST_QUERY_HISTORY_30D",
        "COST_TABLE": f"{schema_fqn}.COST_TABLE",
        "CLOUD_SERVICES_ACCOUNT": f"{schema_fqn}.CLOUD_SERVICES_ACCOUNT_AGG",
        "CLOUD_SERVICES": f"{schema_fqn}.CLOUD_SERVICES_QUERIES",
    }


def rewrite_query(query, table_map):
    def _replace_identifier(m):
        var_name = m.group(1)
        if var_name in table_map:
            return table_map[var_name]
        return m.group(0)
    return re.sub(r'identifier\(\$(\w+)\)', _replace_identifier, query)


def set_session_variables(schema_name):
    cs = get_cursor()
    if is_running_in_sis():
        return
    cs.execute(f"SET SCHEMA_NAME = '{schema_name}'")
    from src.config import SESSION_VARIABLES
    for stmt in SESSION_VARIABLES:
        cs.execute(stmt)


def call_procedure(schema, proc_name, *args):
    args_str = ", ".join(f"'{a}'" if isinstance(a, str) else str(a) for a in args)
    query = f"CALL FINOPS_OUTPUTS.{schema}.{proc_name}({args_str})"
    return run_query(query)
