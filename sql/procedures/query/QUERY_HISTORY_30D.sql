CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.QUERY_HISTORY_30D("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_qh30'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_qh30(session,cust_name: str, deployment_name: str):
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
        session_etl_table = f''SNOWHOUSE_IMPORT.{dep_schema}.SESSION_ETL_V''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        qh_table = f''{schema}.QUERY_HISTORY_30D'';

        # Insert data into identifier table
        insert_query = f"""
        INSERT INTO {qh_table} (
     //   CREATE OR REPLACE TABLE {qh_table} AS (
WITH statement_type AS (
select key::int as id
        , value::string statement_type
      from table(flatten(input => select parse_json(system$dump_enum(''StatementType'')) as statement_type))
)
, cloud_region as (
    select value:id::int as id
         , value:cloud::string as cloud
         , value:region::string as region
    from table(flatten(input => select parse_json(system$dump_enum(''CloudRegions''))))
)
,cloud_regions as (
SELECT snowflake_deployment, cloud_provider_region, cloud
FROM  FINANCE.CUSTOMER.SNOWFLAKE_ACCOUNT_REVENUE_LONG 
WHERE date_trunc(''month'',general_date) = ''{previous_month_start}''
and cloud IS NOT NULL
GROUP BY ALL
)
,WAREHOUSE_CREDITS_PER_HOUR AS (
SELECT
 r.server_type_id
 ,cr.cloud
 ,cr.snowflake_deployment
  ,w.warehouse_type
  ,w.resource_constraint
  ,w.size
  ,w.credits_per_hour
FROM
  FINOPS.PRODUCTS.WAREHOUSE_CONSTRAINT_CREDITS w
CROSS JOIN cloud_regions cr 
LEFT JOIN FINOPS.PRODUCTS.RESOURCE_CONSTRAINT_MAPPING_V r 
    on r.warehouse_type = w.warehouse_type
    and r.resource_constraint = w.resource_constraint
WHERE (w.cloud = ''All'' OR cr.cloud = lower(w.cloud))
GROUP BY ALL
)

SELECT
jev.account_id
,''{deployment}'' as deployment
,jev.warehouse_id
,jev.WAREHOUSE_NAME
,jev.created_on::TIMESTAMP_TZ as DATE
,jev.DESCRIPTION
,CASE 
  WHEN CONTAINS(jev.DESCRIPTION,''-- Looker Query Context'') THEN 1
  ELSE 0
  END AS LOOKER_QUERY_FLAG
,SPLIT_PART(jev.DESCRIPTION,''-- Looker Query Context '',1)::VARCHAR AS QUERY_ONLY
,(REGEXP_REPLACE(
   REGEXP_REPLACE(
    REGEXP_REPLACE(
       REGEXP_REPLACE(jev.DESCRIPTION,''[0-9]{4}\\-[0-9]{2}-[0-9]{2}'',''yyyy-mm-dd''), ''''''.*?'''''', ''''''xxx'''''', 1, 0, ''m'')     
      , ''= \\\\\\d+'', ''= xxx'',1,0,''s'') 
   , ''-- Looker Query Context.*'',''''
)) AS TRIMMED_QUERY 
,SHA1(TRIMMED_QUERY) as QUERY_HASH
,jev.STATS:stats:ioRemoteTempWriteBytes/POW(1024,3) as GB_SPILLED_TO_REMOTE_STORAGE
,st.statement_type as STATEMENT_TYPE
,jev.DPO:"JobDPO:primary":uuid::STRING as QUERY_ID
,jev.JOB_ID
,jev.session_id
,SESS.client_environment
,jev.DPO:"JobDPO:primary":userName::STRING as USERNAME
,jev.DPO:"JobDPO:primary":roleName::STRING as ROLE
,jev.STATS:warehouseSize::int as WAREHOUSE_SERVER_SIZE
,jev.DPO:"JobDPO:stats":warehouseExternalSize::STRING as warehouse_size 
, decode(coalesce(strip_null_value(jev.STATS:currentStateId), strip_null_value(jev.DPO:"JobDPO:stats":currentStateId))::int
            , 15, ''FAIL''
            , 16, ''INCIDENT''
            , 17, ''SUCCESS''
        ) as EXECUTION_STATUS 
, jev.ERROR_MESSAGE as error_message  
, jev.ERROR_CODE as error_code 
,nullif(jev.DPO:"JobDPO:stats":latestClusterNumber::int, -1) + 1 as CLUSTER_NUMBER
,jev.database_name 
,jev.schema_name
, (coalesce(jev.STATS:stats:ioLocalFdnReadBytes::double, 0) + coalesce(jev.STATS:stats:ioRemoteFdnReadBytes::double, 0))::int as bytes_scanned
, div0(nvl(jev.STATS:stats:ioLocalFdnReadBytes::double, 0), nvl(jev.STATS:stats:ioLocalFdnReadBytes::double, 0) + nvl(jev.STATS:stats:ioRemoteFdnReadBytes::double, 0)) as percentage_scanned_from_cache  
, coalesce(jev.STATS:stats:ioRemoteFdnWriteBytes::number, 0) as bytes_written
, coalesce(jev.STATS:stats:ioRemoteResultWriteBytes::number, 0) as bytes_written_to_result
, coalesce(jev.STATS:stats:ioRemoteResultReadBytes::number, 0) as bytes_read_from_result
, jev.STATS:stats:producedRows::int as rows_produced
, coalesce(jev.STATS:stats:numRowsInserted::int, 0)  as rows_inserted
, coalesce(jev.STATS:stats:numRowsUpdated::int, 0)  as rows_updated
, coalesce(jev.STATS:stats:numRowsDeleted::int, 0) as rows_deleted
, coalesce(jev.STATS:stats:numRowsUnloaded::int, 0) as rows_unloaded
, coalesce(jev.STATS:stats:numBytesUnloaded::int, 0) as bytes_deleted
, coalesce(jev.STATS:stats:scanFiles::number, 0) as partitions_scanned
, coalesce(jev.STATS:stats:scanAssignedFiles::number, 0) as partitions_assigned
, coalesce(jev.STATS:stats:scanOriginalFiles::number, 0) as partitions_total
, coalesce(jev.STATS:stats:ioLocalTempWriteBytes::number, 0) as bytes_spilled_to_local_storage
, coalesce(jev.STATS:stats:ioRemoteTempWriteBytes::number, 0) as bytes_spilled_to_remote_storage
, coalesce(jev.STATS:stats:netSentBytes::number, 0) as bytes_sent_over_the_network
, coalesce(jev.STATS:stats.extFuncTotalReceivedBytes::int,0) as external_function_bytes
, coalesce(jev.states_Duration[10], 0)::number + coalesce(jev.states_Duration[14], 0)::number as list_external_files_time
, outbound_cloud_region.cloud as outbound_data_transfer_cloud
, outbound_cloud_region.region as outbound_data_transfer_region
, coalesce(iff(outbound_cloud_region.region is null, 0, jev.STATS:stats:ioRemoteExternalWriteBytes::int), 0) as outbound_data_transfer_bytes
, inbound_cloud_region.cloud as inbound_data_transfer_cloud
, inbound_cloud_region.region as inbound_data_transfer_region
, coalesce(iff(inbound_cloud_region.region is null, 0, jev.STATS:stats:refreshRemoteCopyBytes::int), 0) as inbound_data_transfer_bytes
,jev.DPO:"JobDPO:primary":serverTypeId::INT as server_type_id
,coalesce(stats:stats:gsBillingMicroCreditsInternal::double/1000000.00, 0) as cloud_services_credits_used
,TOTAL_DURATION/1000 AS DURATION_SEC
,(DUR_GS_EXECUTING + 
DUR_XP_EXECUTING + DUR_ABORTING + DUR_GS_POSTEXECUTING + DUR_FAILED_EXECUTION +DUR_WAIT_FILE_DELETION_GATEWAY)/1000 AS EXECUTING_SEC
,DUR_GS_EXECUTING/1000 AS GS_EXECUTING_SEC
,(DUR_QUEUED_REPAIR + DUR_WORKER_GROUP_WAIT + DUR_ABORTING + 
    DUR_FAILED_EXECUTION) / 1000 AS MISC_SEC
,(DUR_WORKER_GROUP_WAIT + DUR_SCHEDULING +DUR_COMPILING + DUR_RECEIVE_QUERY + DUR_WAIT_COMPILATION_GATEWAY + DUR_WAIT_SHOW_COMMAND_GATEWAY + DUR_FILE_SET_INITIALIZATION ) / 1000 AS COMPILING_SEC
,(DUR_QUEUED_LOAD + DUR_QUEUED_RESUMING)/1000 AS QUEUED_SEC
,(DUR_QUEUED_LOAD)/1000 AS QUEUED_LOAD
,(DUR_QUEUED_RESUMING)/1000 AS QUEUED_RESUMING
,(DUR_TXN_LOCK/1000) as TRANSACTION_BLOCKED
,iff(nvl(jev.STATS:stats:warehouseAvailableSize::int, jev.STATS:warehouseSize::int) = 0, null,
            least(round(nvl(jev.STATS:serverCount::int, 0)*100/nvl(jev.STATS:stats:warehouseAvailableSize::int, STATS:warehouseSize::int)), 100)) as QUERY_LOAD_PERCENT
,jev.TAG as QUERY_TAG
,stats:stats:scanFilteredFilesBySearchIndex::NUMBER as SOS_FILTERED_FILES
,stats:stats:scanFilteredFilesBySearchIndex::NUMBER / stats:stats:scanAssignedFiles::NUMBER as SOS_BENEFIT
,CASE WHEN stats:stats:scanFilteredFilesBySearchIndex::NUMBER >0 THEN ''YES'' ELSE ''NO'' END AS SOS_FLAG
,CASE WHEN QAS_CHILD_JOBS IS NOT NULL THEN 1 ELSE 0 END AS QAS_CHILD_JOBS_FLAG
,QAS_CHILD_JOBS
,QAS_PARENT_JOB
,QUERY_PARAMETERIZED_HASH
,QUERY_PARAMETERIZED_HASH_VERSION
,REUSED_JOB_ID
,query_retry_time/1000 as query_retry_sec
,query_retry_cause
,fault_handling_time/1000 as fault_handling_sec
,wh_cr.warehouse_type
,wh_cr.resource_constraint
,wh_cr.credits_per_hour as warehouse_credits_per_hour
FROM {job_etl_table} jev  
JOIN {scoped_table} S
    on jev.account_id = S.account_id
    and S.deployment = ''{deployment}''
JOIN {session_etl_table} SESS
    on jev.account_id = SESS.account_id
    and S.deployment = ''{deployment}''
    and jev.session_id = SESS.id
    and (TO_DATE(SESS.created_on) BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}'') 
left join statement_type st on greatest(coalesce(strip_null_value(jev.DPO:"JobDPO:primary":statementProperties)::int, 0), coalesce(strip_null_value(jev.DPO:"JobDPO:stats":statementProperties)::int, 0)) = st.id 
left join cloud_region as outbound_cloud_region
    on egress_region_id = outbound_cloud_region.id
left join cloud_region as inbound_cloud_region
    on ingress_region_id = inbound_cloud_region.id
left join WAREHOUSE_CREDITS_PER_HOUR as wh_cr
    on wh_cr.snowflake_deployment = ''{deployment}''
    and warehouse_size = wh_cr.size
    and wh_cr.server_type_id = jev.server_type_id
WHERE true
and warehouse_name not like ''COMPUTE_SERVICE_WH%''
and is_internal = FALSE
 AND (TO_DATE(jev.created_on) BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}'')
 )
;
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
