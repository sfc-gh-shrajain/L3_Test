CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.STORAGE_ORCHESTRATOR("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'storage_orchestrator'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def storage_orchestrator(session, cust_name: str):
    try:
        # define variables
        start_time = time.time()
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        FIND_DEPLOYMENTS = f"""
                SELECT DISTINCT DEPLOYMENT
                FROM {scoped_table}
                """
        df = session.sql(FIND_DEPLOYMENTS).collect()
        deploy_list = pd.DataFrame(df).values.tolist()
        #deployments = df[''DEPLOYMENT'']
 #       deploy_list = deploy_list[0]
 
        async_jobs = {}
        res = ''''
        start_with, step = 0, 1
       
        for job_number in range(start_with, len(deploy_list), step):
            async_jobs[job_number] = session.sql(f"""
            call {schema}.storage_deployment(''{customer_name}'',''{deploy_list[job_number][0]}'')
            """).collect_nowait()

        while True:
                if not async_jobs:
                    break
                time.sleep(5)
                for job in async_jobs.copy().keys():
                    if async_jobs[job].is_done():
                        res = res+async_jobs[job].result()[0][0]
                        async_jobs.pop(job, None)

#    end_time = time.time()     
 #       async_jobs = [df.collect_nowait() for df in dfs]
 
        # res = [async_job.result()[0][0] for async_job in async_jobs]
        
        return f''Deployments run: {res}''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
    
';
