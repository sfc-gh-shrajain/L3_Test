CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.COPY_HISTORY_TABLE("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_cht'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_cht(session,cust_name: str):
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
        copy_history = f''{schema}.COPY_HISTORY''
        copy_history_table = f''{schema}.COPY_HISTORY_TABLE''
        copy_history_query = f''{schema}.COPY_HISTORY_QUERY''
        
        # Insert data into identifier table
        insert_query = f"""
//CREATE OR REPLACE TABLE {copy_history_table} AS (
INSERT INTO {copy_history_table} (
WITH QUERY_SIZING AS (
SELECT *
,total_files/8 as suggested_wh_size
,CASE WHEN suggested_wh_size BETWEEN 0 and 1 THEN 1
    WHEN suggested_wh_size BETWEEN 1 and 2 THEN 2
    WHEN suggested_wh_size BETWEEN 2 and 4 THEN 4
    WHEN suggested_wh_size BETWEEN 4 and 8 THEN 8
    WHEN suggested_wh_size BETWEEN 8 and 16 THEN 16
    WHEN suggested_wh_size BETWEEN 16 and 32 THEN 32
    WHEN suggested_wh_size BETWEEN 32 and 64 THEN 64
    WHEN suggested_wh_size BETWEEN 64 and 128 THEN 128
    WHEN suggested_wh_size BETWEEN 128 and 256 THEN 256
    WHEN suggested_wh_size BETWEEN 256 and 512 THEN 512
    ELSE NULL
END as target_wh_size
,CASE WHEN suggested_wh_size BETWEEN 0 and 1 THEN 1
    WHEN suggested_wh_size BETWEEN 1 and 2 THEN 2
    WHEN suggested_wh_size BETWEEN 2 and 4 THEN 3
    WHEN suggested_wh_size BETWEEN 4 and 8 THEN 4
    WHEN suggested_wh_size BETWEEN 8 and 16 THEN 5
    WHEN suggested_wh_size BETWEEN 16 and 32 THEN 6
    WHEN suggested_wh_size BETWEEN 32 and 64 THEN 7
    WHEN suggested_wh_size BETWEEN 64 and 128 THEN 8
    WHEN suggested_wh_size BETWEEN 128 and 256 THEN 9
    WHEN suggested_wh_size BETWEEN 256 and 512 THEN 10
    ELSE NULL
END as target_wh_size_level
,CASE WHEN wh_server_size = 1 THEN 1
    WHEN wh_server_size = 2 THEN 2
    WHEN wh_server_size = 4 THEN 3
    WHEN wh_server_size = 8 THEN 4
    WHEN wh_server_size = 16 THEN 5
    WHEN wh_server_size = 32 THEN 6
    WHEN wh_server_size = 64 THEN 7
    WHEN wh_server_size = 128 THEN 8
    WHEN wh_server_size = 256 THEN 9
    WHEN wh_server_size = 512 THEN 10
    ELSE NULL
END as current_wh_size_level
,target_wh_size_level - current_wh_size_level as sizing_level_delta
FROM {copy_history_query} c
)
, table_cost as (
    SELECT 
    c.account_id
    ,c.deployment
    ,c.table_name
    ,INGEST_TYPE
    ,SUM(credits_attributed_compute) as total_credits
    ,DIV0(sum(sizing_level_delta*credits_attributed_compute),sum(credits_attributed_compute)) as avg_sizing_diff
    ,DIV0(sum(wh_server_size*credits_attributed_compute),sum(credits_attributed_compute)) as avg_wh_server_size
    ,COUNT(*) as total_queries
    //,DIV0(total_credits,(total_mbs_loaded/1024/1024)) as credits_per_tb_scanned
    ,ceil(avg_sizing_diff) as conservative_wh_sizing_diff
   // ,total_credits*(1/pow(2,abs(sizing))) as new_total_credits
   // ,DIV0(new_total_credits,(total_mbs_loaded/1024/1024)) as credits_per_tb_scanned
    FROM QUERY_SIZING c
    WHERE INGEST_TYPE = ''COPY COMMAND''
    GROUP BY ALL
    )

SELECT 
c.account_id
,c.deployment
,c.table_name
,c.ingest_type
,COUNT(file_path) as  total_files 
,t.total_queries
,avg(file_size)/(1024*1024) as avg_file_size_mb
,max(file_size)/(1024*1024) as max_file_size_mb
,min(file_size)/(1024*1024) as min_file_size_mb
,sum(file_size)/(1024*1024) as total_file_size_mb
,stddev(file_size)/(1024*1024) as stddev_file_size_mb
,sum(case when file_size/(1024*1024) > 250 then 1 else 0 end ) file_over_250mb
,sum(case when (file_size)/(1024*1024) < 100 then 1 else 0 end ) file_under_100mb
,sum(case when (file_size)/(1024*1024) < 10 then 1 else 0 end ) file_under_10mb
,percentile_cont(0.5) WITHIN GROUP (ORDER BY file_size/(1024*1024)) as p50_filze_size
,percentile_cont(0.8) WITHIN GROUP (ORDER BY file_size/(1024*1024))   as p80_filze_size
,percentile_cont(0.95) WITHIN GROUP (ORDER BY file_size/(1024*1024)) as p95_filze_size
,t.total_credits
,t.avg_wh_server_size
,t.conservative_wh_sizing_diff
FROM {copy_history} c
JOIN table_cost t
    on t.account_id = c.account_id
    and t.deployment = c.deployment
    and t.table_name = c.table_name
    and t.ingest_type = c.ingest_type
WHERE true
GROUP BY ALL
)
;
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
