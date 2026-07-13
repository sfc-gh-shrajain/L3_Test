CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.SNOWPIPE_PIPE_ANALYSIS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_sp'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_sp(session,cust_name: str):
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
        # deployment = deployment_name.lower()
        # dep_schema = deployment.replace("-", "_")
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        sp_table = f''{schema}.SNOWPIPE_PIPE_ANALYSIS''
        # metering_table = f''SNOWHOUSE_IMPORT.{dep_schema}.wa_metrics_ingest_min_v2_etl_v''
        # pipe_etl = f''SNOWHOUSE_IMPORT.{dep_schema}.pipe_etl_v''
        snowpipe_copy_history = f''{schema}.SNOWPIPE_COPY_HISTORY''

        # Insert data into identifier table
        insert_query = f"""
        CREATE OR REPLACE TABLE {sp_table} as (
       // INSERT INTO {sp_table} (

WITH TABLE_LOADING AS (
SELECT
account_id
,deployment
,table_name
,pipe_id
,ingest_type
,COUNT(file_path) as  total_files 
,avg(file_size)/(1024*1024) as avg_file_size_mb
,max(file_size)/(1024*1024) as max_file_size_mb
,min(file_size)/(1024*1024) as min_file_size_mb
,sum(file_size)/(1024*1024) as total_file_size_mb
,stddev(file_size)/(1024*1024) as stddev_file_size_mb
,DIV0(abs(avg_file_size_mb-stddev_file_size_mb),avg_file_size_mb) as std_diff_from_mean
,sum(case when file_size/(1024*1024) > 250 then 1 else 0 end ) file_over_250mb
,sum(case when (file_size)/(1024*1024) < 100 then 1 else 0 end ) file_under_100mb
,sum(case when (file_size)/(1024*1024) < 10 then 1 else 0 end ) file_under_10mb
,(DIV0((file_under_10mb+file_over_250mb),total_files)) * 100 as percent_improperly_sized
,percentile_cont(0.5) WITHIN GROUP (ORDER BY file_size/(1024*1024)) as p50_filze_size
,percentile_cont(0.8) WITHIN GROUP (ORDER BY file_size/(1024*1024))   as p80_filze_size
,percentile_cont(0.95) WITHIN GROUP (ORDER BY file_size/(1024*1024)) as p95_filze_size
FROM {snowpipe_copy_history}
GROUP BY ALL
)

select
    p.account_id,
    p.account_name,
    p.deployment,
    pipe_name,
    pipe_schema,
    pipe_catalog,
//    p.table_name,
    tl.table_name as table_name,
    count(*) as pipe_runs,
    MAX(start_time) as max_date,
    MIN(start_time) as min_date,
    sum(credits_used) as sum_credits,
    sum(files_inserted) as sum_files_inserted,
    sum_files_inserted / 1000 * 0.06 as sum_credits_files,
    DIV0(sum_credits_files,sum_credits) as percent_files,
    sum_credits - sum_credits_files as sum_credits_wh,
    DIV0(sum_credits_wh,sum_credits) as percent_wh,
    sum(bytes_inserted) / 1024 / 1024 as mb_inserted,
   // Div0(mb_inserted,sum_files_inserted) as avg_mb_per_file_inserted,
    DIV0(sum_credits,(sum(bytes_inserted) / 1024/1024/1024/1024)) as cred_per_TB
    ,MAX(total_files) as total_files             
    ,MAX(tl.avg_file_size_mb) as avg_file_size_mb
    ,MAX(max_file_size_mb) as max_file_size_mb
    ,MAX(min_file_size_mb) as min_file_size_mb
    ,MAX(total_file_size_mb) as total_file_size_mb
    ,MAX(stddev_file_size_mb) as stddev_file_size_mb
    ,MAX(std_diff_from_mean) as std_diff_from_mean
    ,MAX(file_over_250mb) as file_over_250mb
    ,MAX(file_under_100mb) as file_under_100mb
    ,MAX(file_under_10mb) as file_under_10mb
    ,MAX(percent_improperly_sized) as percent_improperly_sized
    ,MAX(p50_filze_size) as p50_filze_size
    ,MAX(p80_filze_size) as p80_filze_size
    ,MAX(p95_filze_size) as p95_filze_size
    from  
        (
        SELECT 
        m.account_id
        ,aev.account_name
        ,m.deployment
        , entity_id as pipe_id
        , pipes.name as pipe_name
        , pipes.table_database_name as pipe_catalog
        , pipes.table_schema_name as pipe_schema
        , pipes.table_name
        , usage_time as start_time
        , dateadd(minute, 60, start_time) as end_time
        , SUM(credits) as credits_used
        , SUM(bytes_inserted) as bytes_inserted
        , SUM(files_inserted) as files_inserted
        FROM METERING_IMPORT.PROD.DATA_INGESTION_METERING_V m
        join {scoped_table} aev on aev.account_id = m.account_id and m.deployment = aev.deployment
        left join SNOWHOUSE_IMPORT.prod.PIPE_ETL_V pipes
            on m.entity_id = pipes.id
            and m.account_id = pipes.account_id
            and m.deployment = pipes.deployment
        WHERE 1 = 1
       // m.account_id = 41337
       // and m.deployment = ''ie''
        and usage_time::DATE BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}''
        and entity_id != 0
        and pipes.deleted_on is null
        GROUP BY ALL
    ) p
    left join TABLE_LOADING tl
            on tl.account_id = p.account_id
            and tl.deployment = p.deployment
            and tl.pipe_id = p.pipe_id
group by all
//order by cred_per_TB desc
);
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
