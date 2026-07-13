CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.TABLES2("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_t2'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_t2(session,cust_name: str, deployment_name: str):
    try:
        # Define and set variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''

        # Set deployment variables
        deployment = deployment_name.lower()
        dep_schema = deployment.replace("-", "_")
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        t2_table = f''{schema}.tables2'';
        t_table_etl_v   = f''snowhouse_import.{dep_schema}.table_etl_v'';

        # Insert data into identifier table
        insert_query = f"""
        INSERT INTO {t2_table}
                (select  
                  table_etl.dpo:"TableDPO:primary".accountId::int as account_id
                  ,''{deployment}''                                  as deployment
                  ,table_etl.id as table_id
                  , strip_null_value(table_etl.dpo:"TableDPO:primary".name)::string as table_name
                  , decode(
                      table_etl.dpo:"TableDPO:primary".kindId::int
                      , 1, ''BASE TABLE''
                      , 2, ''LOCAL TEMPORARY''
                      , 3, ''VIEW''
                      , 8, ''MATERIALIZED VIEW''
                      , 9, ''EXTERNAL TABLE'') as table_type
                  , iff(strip_null_value(table_etl.dpo:"TableDPO:primary".dataTransient)::boolean, ''YES'', ''NO'') as is_transient       
                  , iff(coalesce(strip_null_value(table_etl.dpo:"TableDPO:primary".isAutoClusteringOn)::boolean, false), ''YES'', ''NO'') as auto_clustering_on
                from  {t_table_etl_v} table_etl
                join {scoped_table} S
                    on table_etl.account_id = S.account_id
                    and ''{deployment}'' = S.deployment
                );
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
