CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.COPY_HISTORY("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_ccr'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_ccr(session,cust_name: str, deployment_name: str):
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
        job_etl_v = f''SNOWHOUSE_IMPORT.{dep_schema}.JOB_ETL_V''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        t_load_history_v2_v =  f''SNOWHOUSE_IMPORT.{dep_schema}.load_history_v2_v''
        copy_history = f''{schema}.COPY_HISTORY''
        table_etl_v  =  f''SNOWHOUSE_IMPORT.{dep_schema}.table_etl_v''
        schema_etl_v  =  f''SNOWHOUSE_IMPORT.{dep_schema}.schema_etl_v''
        database_etl_v  =  f''SNOWHOUSE_IMPORT.{dep_schema}.database_etl_v''
        
        # Insert data into identifier table
        insert_query = f"""
        INSERT INTO {copy_history} (
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
//copy command
SELECT 
load_history.account_id
,''{deployment}'' as deployment
,jev.warehouse_name
,t2.TABLE_NAME
,''COPY COMMAND'' as INGEST_TYPE
,load_history.table_id
,load_history.user_id
,jev.uuid as query_id
,load_history.job_created_on
//,(load_history.line:jobCreatedOn::int/1000)::TIMESTAMP as job_created_on
,load_history.file_size
,load_history.file_path
,load_history.row_count
,load_history.error_count
,NULL AS first_error_message --7 deployments don''t have the load_history.first_error_message field. Also not necesary for further insight downstream as error_count can notify us of issues.
FROM {t_load_history_v2_v} as load_history
join {scoped_table} S
    on S.account_id = load_history.account_id
    and S.deployment = ''{deployment}''
left join TABLE_CONFIG t2
on load_history.TABLE_ID = t2.TABLE_ID
and t2.deployment = ''{deployment}''
LEFT JOIN {job_etl_v} jev on
    jev.account_id = load_history.account_id
 and jev.created_on::DATE BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}'' 
    and jev.job_id = load_history.job_id
WHERE job_created_on::DATE BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}'' 
//(load_history.line:jobCreatedOn::int/1000)::TIMESTAMP::DATE BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}'' 
GROUP BY ALL
//ORDER BY account_id, deployment, avg_file_size_mb DESC
)
;
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
