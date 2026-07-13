CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.WAREHOUSE_CONFIGURATION("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_wcon'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_wcon(session,cust_name: str):
    try:
        # Define and set variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''

        # Set deployment variables
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        config_table = f''{schema}.WAREHOUSE_CONFIGURATION'';
        credits_table = f''{schema}.WAREHOUSE_CREDITS'';

        # Insert data into identifier table
        INSERT_QUERY = f"""
INSERT INTO {config_table} (
WITH DEFAULT_TIMEOUT AS (
SELECT 
sf_id as salesforce_account_id
,sf_name as salesforce_account_name
,account_id
,deployment
,48 as TIMEOUT_HOURS
,8 AS MAX_CONCURRENCY_LEVEL
FROM {scoped_table} as map
),
WH_ACCOUNT AS (
SELECT 
d.salesforce_account_id
,d.salesforce_account_name
,m.account_id
,m.deployment
,warehouse_id
,warehouse_name
,TIMEOUT_HOURS
,MAX_CONCURRENCY_LEVEL
FROM {credits_table} m
JOIN DEFAULT_TIMEOUT d 
    on d.deployment = m.deployment
    and d.account_id = m.account_id
),
CUSTOMER_SET_TIMEOUTS AS (
SELECT 
        sf_id as salesforce_account_id
        ,sf_name as salesforce_account_name
        ,param.account_id
        ,param.deployment
        ,LEVEL
        ,ENTITY_ID
        ,MAX(CASE WHEN PARAMETER_NAME = ''STATEMENT_TIMEOUT_IN_SECONDS'' THEN PARAMETER_VALUE/3600 ELSE NULL END) as TIMEOUT_HOURS
        ,MAX(CASE WHEN PARAMETER_NAME = ''MAX_CONCURRENCY_LEVEL'' THEN PARAMETER_VALUE ELSE NULL END) as MAX_CONCURRENCY_LEVEL
    FROM snowhouse_import.prod.parameters_etl_v param
    join {scoped_table} S
        on param.account_id = S.account_id
        and param.deployment= S.deployment
    where true
    AND PARAMETER_NAME IN (''MAX_CONCURRENCY_LEVEL'',''STATEMENT_TIMEOUT_IN_SECONDS'')
    GROUP BY ALL
),
WAREHOUSE_SETTINGS AS (
SELECT 
wh.account_id
,wh.deployment
,id as warehouse_id
,name as warehouse_name
,warehouse_type
,instance_type
,size as current_size
,enable_query_acceleration as query_acceleration_enabled
,query_acceleration_max_scale_factor
,CASE wh.MCW_SCALING_TYPE_ID
        WHEN NULL THEN ''NONE''
        WHEN 1 THEN ''Legacy''
        WHEN 2 THEN ''Standard''
        WHEN 3 THEN ''Economy''
        WHEN 4 THEN ''Extreme''
        ELSE ''-Unknown-'' END AS MCW_SCALING_TYPE
,min_cluster_count
,max_cluster_count
, parse_json(to_variant(wh.management_policy)):"maxIdleTime"::number as auto_suspend
, upper(parse_json(to_variant(wh.management_policy)):"autoResume") as auto_resume
//,to_variant(wh.management_policy)                               as management_policy
, wh.COMMENT                                                   as COMMENT
, CONTAINS(wh.name , ''ETL'')                                    as ETL
FROM snowhouse_import.prod.warehouse_etl_v wh
JOIN {scoped_table} S
        on wh.account_id = S.account_id
        and wh.deployment= S.deployment
WHERE wh.deleted_on IS NULL
)

SELECT 
 wa.salesforce_account_id
,wa.salesforce_account_name
,wa.account_id
,wa.deployment
,wa.warehouse_id
,wa.warehouse_name
,COALESCE(cstw.TIMEOUT_HOURS,csta.TIMEOUT_HOURS,wa.TIMEOUT_HOURS)::NUMBER(10,4) as TIMEOUT_HOURS
,COALESCE(cstw.MAX_CONCURRENCY_LEVEL,csta.MAX_CONCURRENCY_LEVEL,wa.MAX_CONCURRENCY_LEVEL)::NUMBER(10,4) as MAX_CONCURRENCY_LEVEL
,warehouse_type
,instance_type
,current_size
,query_acceleration_enabled
,query_acceleration_max_scale_factor
,MCW_SCALING_TYPE
,min_cluster_count
,max_cluster_count
,auto_suspend
,auto_resume
//,management_policy
,COMMENT
,ETL
FROM WH_ACCOUNT wa
LEFT JOIN CUSTOMER_SET_TIMEOUTS csta 
    on wa.account_id = csta.account_id 
    and wa.deployment = csta.deployment
    and csta.level = ''ACCOUNT''
    and csta.entity_id = wa.account_id
LEFT JOIN CUSTOMER_SET_TIMEOUTS cstw 
    on wa.account_id = cstw.account_id 
    and wa.deployment = cstw.deployment
    and cstw.level = ''WAREHOUSE''
    and cstw.entity_id = wa.warehouse_id
LEFT JOIN WAREHOUSE_SETTINGS ws
    on ws.account_id = wa.account_id
    and ws.deployment = wa.deployment
    and ws.warehouse_id = wa.warehouse_id
    )
;
        """

        # Execute the insert query
        session.sql(INSERT_QUERY).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
