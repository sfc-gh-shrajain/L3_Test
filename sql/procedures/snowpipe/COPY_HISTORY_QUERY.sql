CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.COPY_HISTORY_QUERY("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_chq'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_chq(session,cust_name: str):
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

        # Set deployment variables
        attributed_history = f''{schema}.ATTRIBUTED_COST_QUERY_HISTORY_30D''
        copy_history_query = f''{schema}.COPY_HISTORY_QUERY''
        copy_history = f''{schema}.COPY_HISTORY''
        
        # Insert data into identifier table
        insert_query = f"""
//CREATE OR REPLACE TABLE {copy_history_query} AS (
INSERT INTO {copy_history_query} (
WITH QUERY_AGG AS (
SELECT 
    t.account_id
    ,t.deployment
    ,TABLE_NAME
    ,INGEST_TYPE
    ,WAREHOUSE_NAME
    ,query_id
    ,COUNT(file_path) as  total_files 
    ,avg(file_size)/(1024*1024) as avg_file_size_mb
    ,max(file_size)/(1024*1024) as max_file_size_mb
    ,min(file_size)/(1024*1024) as min_file_size_mb
    ,sum(file_size)/(1024*1024) as total_file_size_mb
    ,stddev(file_size)/(1024*1024) as stddev_file_size_mb
//    ,abs(avg_file_size_mb-stddev_file_size_mb)/avg_file_size_mb as std_diff
FROM {copy_history} t
WHERE true
and INGEST_TYPE = ''COPY COMMAND''
GROUP BY ALL
)

SELECT 
    q.account_id
    ,q.deployment
    ,table_name
    ,INGEST_TYPE
    ,q.warehouse_name
    ,c.avg_wh_size as wh_server_size
    ,q.query_id
    ,total_files 
    ,avg_file_size_mb
    ,max_file_size_mb
    ,min_file_size_mb
    ,total_file_size_mb
    ,stddev_file_size_mb
    ,c.credits_attributed_compute
FROM QUERY_AGG q
JOIN {attributed_history} c 
    on q.account_id = c.account_id
    and q.deployment = c.deployment
    and q.query_id = c.query_id
);
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
