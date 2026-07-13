CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.WAREHOUSE_LOAD("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_wl'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_wl(session,cust_name: str, deployment_name: str):
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
        t_wa_metrics =  f''SNOWHOUSE_IMPORT.{dep_schema}.wa_metrics_stats_min_v2_etl_v''
        t_warehouse = f''SNOWHOUSE_IMPORT.{dep_schema}.warehouse_etl_v''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        whl_table = f''{schema}.WAREHOUSE_LOAD_HISTORY'';

        # Insert data into identifier table
        insert_query = f"""
        INSERT INTO {whl_table}
             WITH WAREHOUSE_DATA AS (
        select 
            wa_metric.account_id
            ,wa_metric.entity_id as warehouse_id
            ,w.name as warehouse_name
            ,wa_metric.start_time_id
            ,wa_metric.duration
            ,TRY_PARSE_JSON(wa_metric.metric) as metric
        from {t_wa_metrics} as wa_metric
        JOIN {scoped_table} s 
            on s.account_id = wa_metric.account_id
            and s.deployment = ''{deployment}''
        JOIN {t_warehouse} as w
            on w.id = wa_metric.entity_id
            and w.account_id = wa_metric.account_id
        and wa_metric.entity_id NOT IN (0,-2)
        and wa_metric.start_time_id::DATE BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}''
        ),
        WH_LOAD AS(
        select 
                          account_id
                          ,parsed.start_time_id as start_time
                          ,dateadd(second, parsed.duration, parsed.start_time_id) as end_time
                          ,warehouse_id
                          ,warehouse_name
                          ,to_number((zeroifnull(parsed.metric[46]) + zeroifnull(parsed.metric[47]) + zeroifnull(parsed.metric[51]) +
                                   zeroifnull(parsed.metric[52]) + zeroifnull(parsed.metric[54])) / (parsed.duration * 1000), 38, 9) as avg_running
                          ,to_number(zeroifnull(parsed.metric[48]) / (parsed.duration * 1000), 38, 9) as avg_queued_load
                          ,to_number((zeroifnull(parsed.metric[49]) + zeroifnull(parsed.metric[50])) / (parsed.duration * 1000), 38, 9) as avg_queued_provisioning
                          ,to_number(zeroifnull(parsed.metric[53]) / (parsed.duration * 1000), 38, 9) as avg_blocked
        FROM WAREHOUSE_DATA parsed)
        SELECT
        DATE_TRUNC(''month'', start_time::DATE) as MONTH
        , WH_LOAD.account_id
        ,''{deployment}'' as deployment
        , WH_LOAD.WAREHOUSE_ID
        , WH_LOAD.WAREHOUSE_NAME
        , AVG(AVG_RUNNING) as AVG_RUNNING
        , APPROX_PERCENTILE(AVG_RUNNING, 0.8) as p80
        , APPROX_PERCENTILE(AVG_RUNNING, 0.95) as p95
        , AVG(AVG_QUEUED_LOAD) as AVG_QUEUED_LOAD
        FROM WH_LOAD
        GROUP BY ALL
        ORDER BY p95 DESC
        ;
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
