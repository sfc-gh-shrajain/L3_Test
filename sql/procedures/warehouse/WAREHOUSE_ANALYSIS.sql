CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.WAREHOUSE_ANALYSIS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'wh_analysis'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def wh_analysis(session, cust_name: str):
    try:
        # define variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        
    #Define Concurrent Queries (1st Set)
        q1 = session.sql(f"""
        call {schema}.warehouse_orchestrator(''{customer_name}'')
        """)
        q2 = session.sql(f"""
        call {schema}.warehouse_credits(''{customer_name}'')
        """)
        q3 = session.sql(f"""
        call {schema}.warehouse_utilization(''{customer_name}'')
        """)
        dfs_1 = [q1,q2,q3]
        
     #Run Concurrent Queries (1st Set)
        async_jobs_1 = [df.collect_nowait() for df in dfs_1]
        res_1 = [async_job.result() for async_job in async_jobs_1]

     #Define Concurrent Queries (2nd Set)
        q4 = session.sql(f"""
        call {schema}.warehouse_configuration(''{customer_name}'')
        """)
        q5 = session.sql(f"""
        call {schema}.warehouse_scoring(''{customer_name}'')
        """)
        dfs_2 = [q4,q5]
        
     #Run Concurrent Queries (2nd Set) 
        async_jobs_2 = [df.collect_nowait() for df in dfs_2]
        res_2 = [async_job.result() for async_job in async_jobs_2]

    #Run Final Queries
        q6 = session.sql(f"""
        call {schema}.warehouse_views(''{customer_name}'')
        """).collect()

    #Aggregate Results
        all_results = [res_1,res_2,q6]

    #Return the values of each query being run
        return f''Completed all warehouse tables {all_results}''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
    
';
