import snowflake.connector
import pandas as pd
import streamlit as st
from src.config import (
    SNOWFLAKE_USER,
    SNOWFLAKE_ACCOUNT,
    SNOWFLAKE_ROLE,
    SNOWFLAKE_WAREHOUSE,
)


@st.cache_resource
def get_connection():
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


def set_session_variables(schema_name):
    cs = get_cursor()
    cs.execute(f"SET SCHEMA_NAME = '{schema_name}'")
    from src.config import SESSION_VARIABLES
    for stmt in SESSION_VARIABLES:
        cs.execute(stmt)


def call_procedure(schema, proc_name, *args):
    args_str = ", ".join(f"'{a}'" if isinstance(a, str) else str(a) for a in args)
    query = f"CALL FINOPS_OUTPUTS.{schema}.{proc_name}({args_str})"
    return run_query(query)
