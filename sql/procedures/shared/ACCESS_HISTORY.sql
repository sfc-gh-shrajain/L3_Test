CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.ACCESS_HISTORY("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_ah'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_ah(session,cust_name: str, deployment_name: str):
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

        # Set deployment & table variables
        deployment = deployment_name.lower()
        dep_schema = deployment.replace("-", "_")
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        ah_table = f''{schema}.ACCESS_HISTORY''
        t_configuration_id_table_etl_v  = f''snowhouse_import.{dep_schema}.configuration_id_table_etl_v'';
        t_configuration_account_etl_v   = f''snowhouse_import.{dep_schema}.configuration_account_etl_v'';
        t_table_access_logs_v           = f''snowhouse_import.{dep_schema}.access_history_log_raw_v'';

        # Insert data into identifier table
        insert_query = f"""
       INSERT INTO {ah_table} 
    ( with access_history_enabled as ( select count(*) > 0 as enabled
                    from
                         {t_configuration_id_table_etl_v} configuration_ids,
                         {t_configuration_account_etl_v} configurations,
                         {scoped_table} S
                    where configuration_ids.dpo:"ConfigurationIdTableDPO:primary":parameterId::number = configurations.dpo:"ConfigurationDPO:primary".keyId::number
                    and configuration_ids.dpo:"ConfigurationIdTableDPO:primary".parameterName::string = ''ENABLE_ACCOUNT_USAGE_ACCESS_HISTORY''
                    and configurations.dpo:"ConfigurationDPO:primary".booleanValue::boolean = true
                    and configurations.dpo:"ConfigurationDPO:primary".entityId::int = S.account_id
                    and S.deployment = ''{deployment}''
                ),
                ACCESS_HISTORY AS (
                select distinct 
                     t.ACCOUNT_ID
                    ,''{deployment}'' as deployment
                    ,JOB_UUID AS query_id
                    ,CREATED_ON AS query_start_time
                    ,USER_NAME
                    ,ACCESS_INFO_SET AS direct_objects_accessed
                    ,BASE_ACCESS_INFO_SET AS base_objects_accessed
                    ,NVL(OBJECTS_MODIFIED, ARRAY_CONSTRUCT()) AS objects_modified
                from {t_table_access_logs_v} t
                JOIN {scoped_table} S
                    ON t.ACCOUNT_ID = S.account_id
                    and S.deployment = ''{deployment}''
                where   (SELECT enabled FROM access_history_enabled)
                    AND LOG_TYPE = ''TOP_AND_BOTTOM_LEVEL''
                    AND SESSION_ID != 0
                    AND TO_DATE(CREATED_ON) >= DATEADD(month, -3, DATE_TRUNC(month, CURRENT_DATE))
                        )
                        
select  account_id, deployment, f1.value:"objectName"::string Table_name
, ''direct_access'' access_type
, COUNT(*) Number_of_accesses
  //, COUNT(DISTINCT to_date(query_start_time)) distinct_days_accessed, min(to_date(query_start_time)) min_accessed, max(to_date(query_start_time)) max_accessed
from ACCESS_HISTORY,
lateral flatten(DIRECT_OBJECTS_ACCESSED) f1
where  f1.value:"objectDomain"::string in (''Table'' , ''Materialized view'',''Event table'',''Dynamic table'')
group by ALL

union

select   account_id, deployment, f1.value:"objectName"::string Table_Name, ''indirect_access'' access_type
  , COUNT(*) Number_of_accesses
  //, COUNT(DISTINCT to_date(query_start_time)) distinct_days_accessed, min(to_date(query_start_time)) min_accessed, max(to_date(query_start_time)) max_accessed
from ACCESS_HISTORY, 
lateral flatten(BASE_OBJECTS_ACCESSED) f1
where f1.value:"objectDomain"::string  in (''Table'' , ''Materialized view'',''Event table'',''Dynamic table'')
group by ALL);
        """

        # Execute the CTAS query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
