CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.STORAGE_ANALYSIS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'storage_analysis'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def storage_analysis(session, cust_name: str):
    try:
        # define variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        
    #Run Deployment Queries (1st Set)
        q1 = session.sql(f"""
        call {schema}.storage_orchestrator(''{customer_name}'')
        """).collect()
        q2 = session.sql(f"""
        call {schema}.storage_views(''{customer_name}'')
        """).collect()
 
    #Aggregate Results
        all_results = [q1,q2]

    #Return the values of each query being run
        return f''Completed all storage tables {all_results}''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
    
';
