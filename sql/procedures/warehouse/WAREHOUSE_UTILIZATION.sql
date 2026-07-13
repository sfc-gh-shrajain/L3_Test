CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.WAREHOUSE_UTILIZATION("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_wu'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_wu(session,cust_name: str):
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
        wu_table = f''{schema}.WAREHOUSE_UTILIZATION'';

        # Insert data into identifier table
        INSERT_QUERY = f"""
       INSERT INTO {wu_table}
    WITH UTILIZATION AS (
        select 
            to_date(START_MINUTE) as ACTIVITY_DATE, 
            u.ACCOUNT_ID,
            u.deployment,
            WAREHOUSE_ID as WAREHOUSE_ID, 
            AVG(AVG_UTILIZATION) as Utilization
            , APPROX_PERCENTILE(AVG_UTILIZATION, 0.8) as p80
            , APPROX_PERCENTILE(AVG_UTILIZATION, 0.95) as p95
            from snowscience.operational_analytics.warehouse_utilization_per_size u
            JOIN {scoped_table} S 
            on u.account_id = S.ACCOUNT_ID
            and u.deployment = S.deployment
            where true
            AND START_MINUTE::DATE BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}''
            and AVG_UTILIZATION > 0
            GROUP BY ALL)
            SELECT 
            ACCOUNT_ID
            , deployment
            , WAREHOUSE_ID
            , AVG(Utilization) as "AVG"
            , AVG(p80) as P80
            , AVG(p95) as P95
            FROM UTILIZATION
            GROUP BY ALL
            ;
        """

        # Execute the CTAS query
        session.sql(INSERT_QUERY).collect()

        return ''Data Inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
