CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.ACCOUNT_ORCHESTRATOR("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'account_orchestrator'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def account_orchestrator(session, cust_name: str):
    try:
        # define variables
        start_time = time.time()
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        analysis_list = []

        # Create Cost Table
        session.sql(f"""call {schema}.cost_table(''{customer_name}'')""").collect()
 #       analysis_list.append(ct)

    #Determine Analysis to Run
        #Warehouse Analysis
        wa = session.sql(f"""SELECT COUNT(*) FROM {scoped_table} WHERE warehouse_analysis > 0""").collect()[0][0]
        if int(wa) > 0:
            wa_sql = session.sql(f"""call {schema}.warehouse_analysis(''{customer_name}'')""")
            analysis_list.append(wa_sql)
        
        #Query Analysis
        qa = session.sql(f"""SELECT COUNT(*) FROM {scoped_table} WHERE query_analysis > 0""").collect()[0][0]
        if int(qa) > 0:
            qa_sql = session.sql(f"""call {schema}.query_analysis(''{customer_name}'')""")
            analysis_list.append(qa_sql)

        #Storage Analysis
        sa = session.sql(f"""SELECT COUNT(*) FROM {scoped_table} WHERE storage_analysis > 0""").collect()[0][0]
        if int(sa) > 0:
            sa_sql = session.sql(f"""call {schema}.storage_analysis(''{customer_name}'')""")
            analysis_list.append(sa_sql)

        #Usage Context Analysis
        uca = session.sql(f"""SELECT COUNT(*) FROM {scoped_table} WHERE usage_context_analysis > 0""").collect()[0][0]
        if int(uca) > 0:
            uca_sql = session.sql(f"""call {schema}.usage_context_analysis(''{customer_name}'')""")
            analysis_list.append(uca_sql)  

        #Other  Analysis
        oa = session.sql(f"""SELECT COUNT(*) FROM {scoped_table} WHERE other_analysis > 0""").collect()[0][0]
        if int(oa) > 0:
            oa_sql = session.sql(f"""call {schema}.other_analysis(''{customer_name}'')""")
            analysis_list.append(oa_sql)  
            
        #ROI  Analysis
        roia = session.sql(f"""SELECT COUNT(*) FROM {scoped_table} WHERE roi_analysis > 0""").collect()[0][0]
        if int(roia) > 0:
            roia_sql = session.sql(f"""call {schema}.roi_analysis(''{customer_name}'')""")
            analysis_list.append(roia_sql)  

    #Aggregate Results
        async_jobs = [df.collect_nowait() for df in analysis_list]
        res = [async_job.result()[0][0] for async_job in async_jobs]

    #Run Account Consolidation
        session.sql(f"""call {schema}.total_account_savings(''{customer_name}'')""").collect()
#        res.append(ac)
        
    #Return the values of each query being run
    #    return f''{analysis_list}''
        return f''Completed all analysis {res}''
 
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
    
';
