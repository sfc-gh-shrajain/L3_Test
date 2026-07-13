CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.QUERY_DEPLOYMENT("CUST_NAME" VARCHAR, "DEPLOYMENT_VALUE" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'query_deployment'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def query_deployment(session, cust_name: str, DEPLOYMENT_VALUE: str):
    try:
        # define variables
        deployment = DEPLOYMENT_VALUE.lower()
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        
    #Queries to be run in series
        session.sql(f"""
        call {schema}.query_history_30d(''{customer_name}'',''{deployment}'')
        """).collect()
        session.sql(f"""
        call {schema}.query_attribution_30d(''{customer_name}'',''{deployment}'')
        """).collect()
        session.sql(f"""
        call {schema}.copy_history(''{customer_name}'',''{deployment}'')
        """).collect()

    #Return the values of each query being run
        return f''Completed Deployment {deployment}''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
    
';
