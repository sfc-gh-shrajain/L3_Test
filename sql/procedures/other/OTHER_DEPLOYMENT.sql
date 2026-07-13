CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.OTHER_DEPLOYMENT("CUST_NAME" VARCHAR, "DEPLOYMENT_VALUE" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'other_deployment'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def other_deployment(session, cust_name: str, DEPLOYMENT_VALUE: str):
    try:
        # define variables
        deployment = DEPLOYMENT_VALUE.lower()
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        
    #Create Queries to be run concurrently
        q1 = session.sql(f"""
        call {schema}.AUTO_CLUSTER_ANALYSIS(''{customer_name}'',''{deployment}'')
        """)
        q2 = session.sql(f"""
        call {schema}.SNOWPIPE_COPY_HISTORY(''{customer_name}'',''{deployment}'')
        """)
        dfs = [q1,q2]
        
     #Run Concurrent Queries   
        async_jobs = [df.collect_nowait() for df in dfs]
        res = [async_job.result() for async_job in async_jobs]

    #Prior set of queries (snowpipe) before code update
        
    #Return the values of each query being run
        return f''Completed Deployment {deployment}: {res}''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
    
';
