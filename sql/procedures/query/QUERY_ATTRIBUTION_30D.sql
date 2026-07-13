CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.QUERY_ATTRIBUTION_30D("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_qac'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_qac(session,cust_name: str, deployment_name: str):
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
        query_history_table = f''{schema}.QUERY_HISTORY_30D''
        qac_table = f''{schema}.ATTRIBUTED_COST_QUERY_HISTORY_30D''
        
             # Point to the new static view
        base_qac_table = ''RESOURCE_UTILIZATION_IMPORT.PUBLIC.QUERY_ATTRIBUTED_CREDITS_V''


        # Insert data into identifier table
        insert_query = f"""
        INSERT INTO {qac_table} (
        //CREATE OR REPLACE TABLE {qac_table} AS (
        WITH QUERY_HISTORY AS (
        SELECT 
        q.account_id
        ,q.deployment
        ,q.warehouse_name
        ,MIN(q.date) as start_time
        ,LISTAGG(DISTINCT q.warehouse_size, '','') as wh_size_name
        ,q.query_id
        ,q.query_tag
        ,q.query_only
        ,q.query_parameterized_hash
        ,q.query_hash
        ,role
        ,username
        ,LISTAGG( q.error_code, '','') as error_codes
        ,LISTAGG( q.error_message, '','') as error_messages
        ,LISTAGG(job_id,'','') as job_ids
        ,LISTAGG(reused_job_id,'','') as reused_job_ids
        ,MAX(session_id) as session_id
        ,MAX(client_environment) as client_environment
        ,MAX(server_type_id) as server_type_id
        ,SUM(cloud_services_credits_used) as cloud_services_credits
        ,DIV0(SUM(warehouse_server_size),SUM(CASE WHEN warehouse_server_size > 0 THEN 1 ELSE 0 END)) as avg_wh_size
        ,SUM(executing_sec) as executing_sec
        ,SUM(compiling_sec) as compiling_sec
        ,SUM(queued_load) as queueing_sec
        ,SUM(bytes_scanned) as bytes_scanned
        ,MAX(duration_sec) as duration_sec
        ,MAX(query_retry_sec) as query_retry_sec
        ,MAX(query_retry_cause) as query_retry_cause
        ,MAX(fault_handling_sec) as fault_handling_sec
        ,MAX(warehouse_type) as warehouse_type
        ,MAX(resource_constraint) as resource_constraint
        ,MAX(warehouse_credits_per_hour) as warehouse_credits_per_hour
        ,COUNT(*) as queries_rolled_up
        FROM {query_history_table} q
        WHERE q.deployment = ''{deployment}''
        GROUP BY ALL
        )

        SELECT 
        qh.account_id
        ,qh.deployment
        ,warehouse_name
        ,qac.warehouse_id
        ,start_time
        ,wh_size_name
        ,avg_wh_size
        ,qh.query_id
        ,qh.query_tag
        ,qh.query_parameterized_hash
        ,qh.query_hash
        ,query_only
        ,role
        ,username
        ,error_codes
        ,error_messages
        ,job_ids
        ,reused_job_ids
        ,session_id
        ,client_environment
        ,server_type_id
        ,cloud_services_credits
        ,executing_sec
        ,compiling_sec
        ,queueing_sec
        ,bytes_scanned
        ,duration_sec
        ,query_retry_sec
        ,query_retry_cause
        ,fault_handling_sec
        ,queries_rolled_up
        ,IFNULL(qac.credits_attributed_compute,0) as credits_attributed_compute
        ,warehouse_type
        ,resource_constraint
        ,warehouse_credits_per_hour
        FROM QUERY_HISTORY qh
        LEFT JOIN {base_qac_table} qac
                on qh.account_id = qac.account_id 
                and qh.query_id = qac.query_id
                and qac.deployment = ''{deployment}''
                and (qac.start_time_ms/1000)::TIMESTAMP >= DATEADD(day,-1,''{previous_month_start}'')
                )
        ;
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
