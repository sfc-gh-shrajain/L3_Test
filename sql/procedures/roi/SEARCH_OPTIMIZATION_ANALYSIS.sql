CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.SEARCH_OPTIMIZATION_ANALYSIS("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_soa'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_soa(session,cust_name: str, deployment_name: str):
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
        job_etl_table = f''SNOWHOUSE_IMPORT.{dep_schema}.JOB_ETL_V''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        aca_table = f''{schema}.AUTO_CLUSTER_ANALYSIS''
        query_history = f''{schema}.QUERY_HISTORY_30D''
        metering_table = f''SNOWHOUSE_IMPORT.{dep_schema}.WA_METRICS_COMPUTE_SERVICE_HOUR_ETL_V''
        table_etl = f''SNOWHOUSE_IMPORT.{dep_schema}.TABLE_ETL_V''
        schema_etl = f''SNOWHOUSE_IMPORT.{dep_schema}.SCHEMA_ETL_V''
        database_etl = f''SNOWHOUSE_IMPORT.{dep_schema}.DATABASE_ETL_V''

        # Insert data into identifier table
        insert_query = f"""
        INSERT INTO {aca_table}
SELECT 
ACCOUNT_ID
,DEPLOYMENT
,DATABASE_NAME
,SCHEMA_NAME
,TABLE_NAME
,sum(num_bytes_reclustered)/1024/1024/1024 as gb_reclustered
,avg(active_bytes)/1024/1024/1024 as table_active_gb
,sum(bytes_scanned)/1024/1024/1024 as total_gb_scanned
,sum(credits_used) as total_recluster_credits
,sum(jobs) as num_queries
,sum(select_jobs) as select_queries
,SUM(dml_jobs) as dml_jobs
,DIV0(gb_reclustered,table_active_gb) as percent_reclustered
FROM (
SELECT 
aev.account_id
,cs.deployment
,cs.START_TIME
,database_etl.name as DATABASE_NAME
,schema_etl.name as SCHEMA_NAME
,t.NAME as TABLE_NAME
, NULL as TableOperation
//, parse_json(cs.dpo:"WAMetricsDPO:by_subtype_time".metric) as metric_JSON
, SUM(num_bytes_reclustered) as num_bytes_reclustered
, SUM(num_rows_reclustered) as num_rows_reclustered
, SUM(credits_used) as credits_used
,SUM(tu.active_bytes) as active_bytes
,SUM(tu.bytes_scanned) as bytes_scanned
,SUM(tu.jobs) as jobs
,SUM(tu.select_jobs) as select_jobs
,SUM(tu.dml_jobs) as dml_jobs
FROM (
    SELECT 
    cs.account_id
    ,''{deployment}'' as deployment
    ,DATE_TRUNC(''day'',cs.START_TIME_ID) as START_TIME
    ,cs.entity_id
    , NULL as TableOperation
    //, parse_json(cs.dpo:"WAMetricsDPO:by_subtype_time".metric) as metric_JSON
    , SUM(parse_json(cs.dpo:"WAMetricsDPO:by_subtype_time".metric)[2]::int) as num_bytes_reclustered
    , SUM(parse_json(cs.dpo:"WAMetricsDPO:by_subtype_time".metric)[3]::int) as num_rows_reclustered
    , SUM(to_number(coalesce(parse_json(cs.dpo:"WAMetricsDPO:by_subtype_time".metric)[1], 0) / 3600000000.00, 38, 9)) as credits_used
    FROM {metering_table} cs
    join {scoped_table} s
        on cs.account_id = s.account_id
        and s.deployment = ''{deployment}''
    WHERE true
    and  TO_DATE(cs.START_TIME_ID) BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}''
    AND cs.dpo:"WAMetricsDPO:by_subtype_time".metricsTypeId:: number = 16 -- Compute Service Metric
    AND cs.dpo:"WAMetricsDPO:by_subtype_time".metricsSubTypeId:: number = 2 -- Auto Clustering Metric
    AND cs.dpo:"WAMetricsDPO:by_subtype_time".entityId:: number != 0
    GROUP BY ALL
    ) cs
join {scoped_table} aev 
    on aev.account_id = cs.account_id
    and aev.deployment = ''{deployment}''
join {table_etl} t on cs.ENTITY_ID = t.id and t.account_id = cs.account_id
left join {schema_etl} as schema_etl
    on schema_etl.account_id = cs.account_id
    and schema_etl.id = t.parent_id
left join {database_etl} as database_etl
    on database_etl.account_id = cs.account_id
    and database_etl.id = schema_etl.parent_id
left join 
    (SELECT 
    tu.account_id
    ,tu.deployment
    ,DATEADD(''day'',-1,DS) as Date
    ,table_id
    ,SUM(tu.active_bytes) as active_bytes
    ,SUM(tu.bytes_scanned) as bytes_scanned
    ,SUM(tu.jobs ) as jobs
    ,SUM(tu.select_jobs) as select_jobs
    ,SUM(tu.dml_jobs) as dml_jobs
    FROM SNOWSCIENCE.JOB_ANALYTICS.TABLE_USAGE tu 
    join {scoped_table} s 
        on tu.account_id = s.account_id
        and tu.deployment = s.deployment
        and s.deployment = ''{deployment}''
    WHERE true
    and TO_DATE(tu.DS) BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}''
    GROUP BY ALL) tu on tu.account_id = cs.account_id and tu.table_id = cs.ENTITY_ID and tu.date = cs.start_time
WHERE 
1=1
GROUP BY ALL
)
GROUP BY ALL
;
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
