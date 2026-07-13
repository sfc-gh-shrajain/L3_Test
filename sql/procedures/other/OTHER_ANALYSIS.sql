CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.OTHER_ANALYSIS("CUST_NAME" VARCHAR)
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
        call {schema}.other_orchestrator(''{customer_name}'')
        """).collect()
        
    #Run 2nd set of queries
        q2 = session.sql(f"""
        call {schema}.SNOWPIPE_PIPE_ANALYSIS(''{customer_name}'')
        """).collect()
  
    
    #Run Query Views
        q20 = session.sql(f"""
        call {schema}.other_views(''{customer_name}'')
        """).collect()
 
    #Aggregate Results
        all_results = [q1,q2,q20]

    #Return the values of each query being run
        return f''Completed all query tables {all_results}''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
    
';
