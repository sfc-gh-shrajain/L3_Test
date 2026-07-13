CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.QUERY_ANALYSIS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'query_analysis'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def query_analysis(session, cust_name: str):
    try:
        # define variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''

    #Define Queries (1st Set)
        q1 = session.sql(f"""
        call {schema}.query_orchestrator(''{customer_name}'')
        """).collect()

     #Define Concurrent Queries (2nd Set)
        q2 = session.sql(f"""
        call {schema}.query_timeout_waste(''{customer_name}'')
        """)
        q3 = session.sql(f"""
        call {schema}.repeated_queries(''{customer_name}'')
        """)
        q4 = session.sql(f"""
        call {schema}.copy_history_query(''{customer_name}'')
        """)
        
        dfs_2 = [q2,q3,q4]
        
     #Run Concurrent Queries (2nd Set) 
        async_jobs_2 = [df.collect_nowait() for df in dfs_2]
        res_2 = [async_job.result() for async_job in async_jobs_2]

     #Run Additional Copy History Table View
        q10 = session.sql(f"""
        call {schema}.copy_history_table(''{customer_name}'')
        """).collect()
    
    #Run Query Views
        q20 = session.sql(f"""
        call {schema}.query_views(''{customer_name}'')
        """).collect()
 
    #Aggregate Results
        all_results = [q1,res_2,q10,q20]

    #Return the values of each query being run
        return f''Completed all query tables {all_results}''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
    
';
