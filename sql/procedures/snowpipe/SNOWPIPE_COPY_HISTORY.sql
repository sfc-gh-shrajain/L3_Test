CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.SNOWPIPE_COPY_HISTORY("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_sch'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_sch(session,cust_name: str, deployment_name: str):
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
        deployment = deployment_name.lower()
        dep_schema = deployment.replace("-", "_")
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        t_ingest_load_history_raw_v  =  f''SNOWHOUSE_IMPORT.{dep_schema}.ingest_load_history_raw_v''
        snowpipe_copy_history = f''{schema}.SNOWPIPE_COPY_HISTORY''
        table_etl_v  =  f''SNOWHOUSE_IMPORT.{dep_schema}.table_etl_v''
        schema_etl_v  =  f''SNOWHOUSE_IMPORT.{dep_schema}.schema_etl_v''
        database_etl_v  =  f''SNOWHOUSE_IMPORT.{dep_schema}.database_etl_v''
        
        # Insert data into identifier table
        insert_query = f"""
       INSERT INTO {snowpipe_copy_history} (
WITH TABLE_CONFIG AS(
    SELECT t.ACCOUNT_ID
    , ''{deployment}'' as DEPLOYMENT
    , t.ID::int as TABLE_ID
    , d.name || ''.'' || s.name || ''.'' || t.name as table_name
    //, PARENT_ID as SCHEMA_ID
    FROM {table_etl_v} t
    JOIN {scoped_table} a
        on a.account_id = t.account_id
        and a.deployment = ''{deployment}''
    LEFT JOIN {schema_etl_v} s
        on t.account_id = s.account_id
        and t.parent_id = s.id
    LEFT JOIN {database_etl_v} d
        on d.account_id = t.account_id
        and s.parent_id = d.id
    WHERE true
    //and t.deleted_on IS NULL
    and table_name IS NOT NULL
    and t.kind_id IN (1,2,8)
)
//Snowpipe
SELECT 
    ingest_load_history.dpo:"IngestLoadHistoryDPO:pipeCompletedTime":"accountId"::int as account_id
    ,''{deployment}'' as deployment
    ,''SERVERLESS_SERVICE'' as warehouse_name
    ,t2.TABLE_NAME
    ,''SNOWPIPE'' as INGEST_TYPE
    ,ingest_load_history.table_id
    ,ingest_load_history.pipe_id
    ,NULL as user_id
    ,NULL as query_id
    ,(ingest_load_history.dpo:"IngestLoadHistoryDPO:pipeCompletedTime":"timeAdded"::int/1000)::TIMESTAMP as job_created_on
    ,ingest_load_history.file_size
    ,ingest_load_history.file_path
    ,ingest_load_history.rows_inserted as row_count
    ,ingest_load_history.error_count
    ,ingest_load_history.first_error_message
FROM {t_ingest_load_history_raw_v} ingest_load_history
join {scoped_table} S
    on S.account_id = ingest_load_history.dpo:"IngestLoadHistoryDPO:pipeCompletedTime":"accountId"::int
    and S.deployment = ''{deployment}''
left join TABLE_CONFIG t2
    on ingest_load_history.TABLE_ID = t2.TABLE_ID
    and ingest_load_history.dpo:"IngestLoadHistoryDPO:pipeCompletedTime":"accountId"::int = t2.account_id
    and t2.deployment = ''{deployment}''
WHERE (ingest_load_history.dpo:"IngestLoadHistoryDPO:pipeCompletedTime":"timeAdded"::int/1000)::TIMESTAMP::DATE BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}'' 
GROUP BY ALL
)
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
