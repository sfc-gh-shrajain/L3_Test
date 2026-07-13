CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.WAREHOUSE_IDLE_TIME("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_wit'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_wit(session,cust_name: str, deployment_name: str):
    try:
        # Define and set variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        deployment = deployment_name.lower()
        dep_schema = deployment.replace("-", "_")
        

        # Start of Previous Month
        previous_month_start = session.sql("SELECT DATEADD(''month'',-1, DATE_TRUNC(''month'',CURRENT_DATE()))").collect()[0][0]
        previous_month_start = previous_month_start.strftime(''%Y-%m-%d'')

        # End of Previous Month
        previous_month_end = session.sql("SELECT DATEADD(''day'',-1,DATE_TRUNC(''month'',CURRENT_DATE()))").collect()[0][0]
        previous_month_end = previous_month_end.strftime(''%Y-%m-%d'')

        # Set deployment & table variables
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        wit_table = f''{schema}.WAREHOUSE_IDLE_TIME''
        WH_UTILIZATION_WAREHOUSE_LEVEL = f''RESOURCE_UTILIZATION_IMPORT.PUBLIC.WH_UTILIZATION_WAREHOUSE_LEVEL_V''
        WH_UTILIZATION_CLUSTER_LEVEL = f''RESOURCE_UTILIZATION_IMPORT.PUBLIC.WH_UTILIZATION_CLUSTER_LEVEL_V''

        # Insert data into identifier table
        INSERT_QUERY = f"""
        INSERT INTO {wit_table} (
        //CREATE OR REPLACE TABLE {wit_table} AS (
        WITH IDLE_CALC AS (
            SELECT 
                    account_id
                  ,deployment
                  ,warehouse_id
                  ,TO_TIMESTAMP(start_time_ms::INT, 3) AS ts
                  ,is_idle_warehouse
                  ,LAG(ts) OVER (PARTITION BY account_id, warehouse_id ORDER BY ts) AS ts_lag
                  ,LAG(is_idle_warehouse) OVER (PARTITION BY account_id, warehouse_id ORDER BY ts) AS is_idle_warehouse_lag
             //     ,LEAD(ts) OVER (PARTITION BY account_id, warehouse_id ORDER BY ts) AS ts_lead
             //     ,LEAD(is_idle_warehouse) OVER (PARTITION BY account_id, warehouse_id ORDER BY ts) AS is_idle_warehouse_lead
              FROM {WH_UTILIZATION_WAREHOUSE_LEVEL} wh
             WHERE 1 = 1
               AND wh.deployment = ''{deployment}''
               AND DATE_TRUNC(MONTH, ts) = ''{previous_month_start}''
         )
         ,CLUSTER_LEVEL AS (
            SELECT
            account_id
            ,deployment
            ,warehouse_id
            ,TO_TIMESTAMP(start_time_ms::INT, 3) AS ts
            ,SUM(CASE WHEN IS_IDLE_CLUSTER THEN 1 ELSE 0 END) as idle_clusters
            ,COUNT(*) as TOTAL_CLUSTERS
            //,COUNT(*) as num_clusters
            FROM {WH_UTILIZATION_CLUSTER_LEVEL} wh
             WHERE 1 = 1
             AND wh.deployment = ''{deployment}''
            // and account_id = 4002179
             // AND warehouse_id = 1024557868
               AND DATE_TRUNC(MONTH, ts) = ''{previous_month_start}''
            GROUP BY ALL
         )
         
         SELECT 
           C.account_id
          ,C.deployment
          ,C.warehouse_id
          ,DATE_TRUNC(''month'',C.ts) as month_date
          ,SUM(CASE WHEN is_idle_warehouse THEN 1 ELSE 0 END) as idle_clock_minutes
          ,SUM(CASE WHEN is_idle_warehouse AND is_idle_warehouse_lag AND datediff(''minute'',C.ts_lag,C.ts) = 1 THEN 1 ELSE 0 END) as idle_clock_minutes_after_60s
          ,SUM(CASE WHEN is_idle_warehouse AND is_idle_warehouse_lag AND datediff(''minute'',C.ts_lag,C.ts) = 1 THEN cl.idle_clusters ELSE 0 END) as idle_cluster_minutes_after_60s
          ,COUNT(*) as active_clock_minutes
          ,SUM(cl.idle_clusters) as total_idle_cluster_minutes
          ,SUM(cl.TOTAL_CLUSTERS) as total_active_cluster_minutes
        FROM IDLE_CALC C
        LEFT JOIN CLUSTER_LEVEL cl on
            C.account_id = cl.account_id
            and C.warehouse_id = cl.warehouse_id
            and C.deployment = cl.deployment
            and C.ts = cl.ts
        GROUP BY ALL
        //HAVING idle_cluster_minutes_after_60s <> idle_clock_minutes_after_60s
        )
        ;
        """

        # Execute the CTAS query
        session.sql(INSERT_QUERY).collect()

        return ''Data Inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
