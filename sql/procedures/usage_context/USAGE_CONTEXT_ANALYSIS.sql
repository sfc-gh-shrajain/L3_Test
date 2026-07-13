CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.USAGE_CONTEXT_ANALYSIS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'ue_analysis'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def ue_analysis(session, cust_name: str):
    try:
        # define variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        
    #Define Queries (1st Set)
        q1 = session.sql(f"""
        call {schema}.ue_orchestrator(''{customer_name}'')
        """).collect()
        q2 = session.sql(f"""
        call {schema}.usage_context_views(''{customer_name}'')
        """).collect()
        

    #Aggregate Results
        all_results = [q1,q2]

    #Return the values of each query being run
        return f''Completed all usage context tables {all_results}''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
    
';
