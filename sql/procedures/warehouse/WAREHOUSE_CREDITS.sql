CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.WAREHOUSE_CREDITS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_wc'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_wc(session,cust_name: str):
    try:
        # Define and set variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''

        # Start of Previous Month
        previous_month_start = session.sql("SELECT DATEADD(''month'',-1, DATE_TRUNC(''month'',CURRENT_DATE()))").collect()[0][0]
        previous_month_start = previous_month_start.strftime(''%Y-%m-%d'')

        # End of Previous Month
        previous_month_end = session.sql("SELECT DATEADD(''day'',-1,DATE_TRUNC(''month'',CURRENT_DATE()))").collect()[0][0]
        previous_month_end = previous_month_end.strftime(''%Y-%m-%d'')

        # Set deployment & table variables
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        wc_table = f''{schema}.WAREHOUSE_CREDITS'';

        # Insert data into identifier table
        CTAS_QYERY = f"""
       CREATE OR REPLACE TABLE {wc_table} AS (
        select
            YEAR(USAGE_DATE::DATE) || ''-Q''  || QUARTER(USAGE_DATE::DATE) AS PERIOD
            ,DATE_TRUNC(''month'', USAGE_DATE::DATE) as MONTH
            ,m.SNOWFLAKE_ACCOUNT_ID  as ACCOUNT_ID
            ,m.SNOWFLAKE_DEPLOYMENT as DEPLOYMENT
            ,WAREHOUSE_ID
            ,WAREHOUSE_NAME
            ,ROUND(SUM(CREDITS),2) as CREDITS_XP
        from FINANCE.CUSTOMER.WAREHOUSE_COMPUTE m
        JOIN {scoped_table} S 
                on m.snowflake_account_id = S.ACCOUNT_ID
                and m.snowflake_deployment = S.deployment
    WHERE true
    AND m.USAGE_DATE::DATE between ''{previous_month_start}'' AND ''{previous_month_end}''
    AND m.WAREHOUSE_ID NOT IN (0,-2)
    AND m.CREDITS > 0
    GROUP BY ALL );
        """

        # Execute the CTAS query
        session.sql(CTAS_QYERY).collect()

        return ''Table Created successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
