CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.TABLE_STORAGE_METRICS("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_tsm'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_tsm(session,cust_name: str, deployment_name: str):
    try:
        # Define and set variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''

        # Set deployment variables
        deployment = deployment_name.lower()
        dep_schema = deployment.replace("-", "_")
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        tsm_table = f''{schema}.TABLE_STORAGE_METRICS'';
        t_table_etl_v   = f''snowhouse_import.{dep_schema}.table_etl_v''
        t_configuration_etl_v  = f''snowhouse_import.{dep_schema}.configuration_etl_v''
        t_configuration_id_table_etl_v   = f''snowhouse_import.{dep_schema}.configuration_id_table_etl_v''
        t_accounting_etl_v   = f''snowhouse_import.{dep_schema}.accounting_etl_v''
        t_table_etl_v   = f''snowhouse_import.{dep_schema}.table_etl_v''
        t_schema_etl_v   = f''snowhouse_import.{dep_schema}.schema_etl_v''
        t_database_etl_v   = f''snowhouse_import.{dep_schema}.database_etl_v''
        t_parameters_etl_v = f''snowhouse_import.{dep_schema}.parameters_etl_v''

        # Insert data into identifier table
        insert_query = f"""
        INSERT INTO {tsm_table} (
        //CREATE OR REPLACE TABLE {tsm_table} AS (
                    ( with x_accounting as (select
                              accounting_etl.dpo:"AccountingDPO:changelog":accountId::int as account_id
                              , accounting_etl.dpo:"AccountingDPO:changelog":tableId as table_id
                              , parse_json(accounting_etl.dpo:"AccountingDPO:changelog":stats) as stats
                              , accounting_etl.dpo:"AccountingDPO:changelog":tableSrcId as table_source_id
                              , accounting_etl.dpo:"AccountingDPO:changelog":accountingVersion as accounting_version
                              , accounting_etl.dpo:"AccountingDPO:changelog":deletedOn::number > 0 as deleted
                            from {t_accounting_etl_v} as accounting_etl
                            inner join (
                              select 4 as accounting_version  --if the lower query resolves to a null set
                              union --yes, union
                              select
                              configuration_etl.dpo:"ConfigurationDPO:changelog".longValue::int as accounting_version
                              from {t_configuration_etl_v} as configuration_etl
                              left join {t_configuration_id_table_etl_v} as configuration_id_table_etl
                              on configuration_etl.dpo:"ConfigurationDPO:changelog":keyId::int = configuration_id_table_etl.dpo:"ConfigurationIdTableDPO:primary":parameterId::int
                              JOIN {scoped_table} S 
                                on configuration_etl.dpo:"ConfigurationDPO:changelog".entityId::int = S.account_id
                                    and S.deployment = ''{deployment}''
                              where configuration_etl.dpo:"ConfigurationDPO:changelog".namespaceId::int = 1        --ACCOUNT-LEVEL PARAMETER
and configuration_id_table_etl.dpo:"ConfigurationIdTableDPO:primary":parameterName::string = ''EPS3_ACCOUNTING_VERSION''
                            ) as parameter   --determine the accounting version. assumes a default of 4
                            on parameter.accounting_version = accounting_etl.dpo:"AccountingDPO:changelog":accountingVersion::int
                            JOIN {scoped_table} S 
                                on accounting_etl.dpo:"AccountingDPO:changelog":accountId::int = S.account_id
                                    and S.deployment = ''{deployment}''
                            where true
                            and accounting_etl.dpo:"AccountingDPO:changelog":tableId is not null),
x_parameters as (
SELECT 
    account_id
    ,LEVEL
    ,ENTITY_ID
    ,ENTITY_NAME
    ,PARAMETER_NAME
    ,PARAMETER_VALUE
FROM {t_parameters_etl_v} param
WHERE 
parameter_name = ''DATA_RETENTION_TIME_IN_DAYS''
),
x_table_etl_v_stg as (
        select 
        table_etl.account_id
        ,table_etl.id
        ,table_etl.kind_id
        ,table_etl.parent_id
        ,table_etl.comment
        ,table_etl.created_on
        ,table_etl.deleted_on
        ,table_etl.expired_time
        ,table_etl.data_transient
        ,table_etl.source_id
        ,table_etl.name
        ,table_etl.mv_source_table_id
        ,table_etl.mv_type_id
        ,table_etl.mv_search_index_properties
        ,table_etl.iceberg_table_type_id
        , iff(table_etl.is_iceberg, ''YES'', ''NO'') as is_iceberg
        , decode(
                          table_etl.dpo:"TableDPO:primary".kindId::int
                          , 1, ''BASE TABLE''
                          , 2, ''LOCAL TEMPORARY''
                          , 3, ''VIEW''
                          , 8, ''MATERIALIZED VIEW''
                          , 9, ''EXTERNAL TABLE'') as table_type
        , iff(table_etl.DATA_TRANSIENT, ''YES'', ''NO'') as is_transient
        , iff(coalesce(strip_null_value(table_etl.dpo:"TableDPO:primary".isAutoClusteringOn)::boolean, false), ''YES'', ''NO'') as auto_clustering_on
        ,CLUSTER_BY_KEYS
        ,P.PARAMETER_VALUE as DATA_RETENTION_TIME_IN_DAYS
        from 
        //snowhouse_import.azeastus2prod.table_etl_v table_etl
        {t_table_etl_v} as table_etl
        JOIN 
        //FINOPS_OUTPUTS.ATT_COMM_250507.SCOPED_ACCOUNTS S
        {scoped_table} S 
                                    on table_etl.account_id = S.account_id
                                     and S.deployment = ''{deployment}''
                                    //and S.deployment = ''azeastus2prod''
       LEFT JOIN x_parameters P
                on table_etl.account_id = P.account_id
                and table_etl.id = P.entity_id
                and P.level = ''TABLE''
        where true
        and table_etl.kind_id in (1, 2, 8)
        )                 
,SOS_DETAILS AS (
        SELECT 
        account_id
        ,id
        , name
        , mv_search_index_properties
        ,sos.value:exprId::INT as EXPRESSION_ID
        ,sos.value:exprSqlName::VARCHAR as COLUMN_NAME
        ,sos.value:expressionIndexingMethod::VARCHAR as INDEX_TYPE
        ,case 
            when INDEX_TYPE = ''VARCHAR_N_GRAMS'' THEN ''SUBSTRING'' 
            when INDEX_TYPE = ''VARIANT'' THEN ''EQUALITY VARIANT''
            when INDEX_TYPE = ''SINGLE_VALUE_HASHED'' THEN ''EQUALITY''
            when INDEX_TYPE = ''VARIANT_N_GRAMS'' THEN ''SUBSTRING VARIANT''
            when INDEX_TYPE = ''GEOGRAPHY'' THEN ''GEOGRAPHY''
            when INDEX_TYPE = ''VARCHAR_TOKENS'' THEN ''EQUALITY TOKENS''
            when COLUMN_NAME IS NOT NULL AND sos.value:isValid::boolean = true THEN ''ALL TABLE EQUALITY''
            ELSE ''UNKNOWN''
        END as INDEX_CATEGORY
        FROM x_table_etl_v_stg table_etl,
        LATERAL FLATTEN(input=>TRY_PARSE_JSON(table_etl.mv_search_index_properties),path=>''indexedExpressions'') as sos
        where 1 = 1
        and kind_id = 8
        and mv_search_index_properties IS NOT NULL
        //having INDEX_CATEGORY = ''UNKNOWN''
        //GROUP BY INDEX_TYPE
        //and account_id = 2577795
        //and id = 11071545250451466
        )
,COLUMN_AGG AS (
    SELECT 
    account_id
    ,id
    ,name
    ,INDEX_CATEGORY
    ,''('' || LISTAGG(COLUMN_NAME,'','') || '')'' as COLUMNS_AGGS
    FROM SOS_DETAILS
    GROUP BY ALL
    )
,SOS_COLUMNS AS (
    SELECT 
    account_id
    ,id
    ,name
    ,OBJECT_AGG(INDEX_CATEGORY,COLUMNS_AGGS::VARIANT) as SOS_COLUMNS
    FROM COLUMN_AGG
    GROUP BY ALL
    )     
, x_table_etl_v as
    (
    SELECT 
    table_etl.account_id
    ,table_etl.id
    ,table_etl.kind_id
    ,table_etl.parent_id
    ,table_etl.comment
    ,table_etl.created_on
    ,table_etl.deleted_on
    ,table_etl.expired_time
    ,table_etl.data_transient
    ,table_etl.source_id
    ,table_etl.name
    ,table_etl.mv_source_table_id
    ,table_etl.mv_type_id
    ,table_etl.mv_search_index_properties
    ,table_etl.iceberg_table_type_id
    ,table_etl.is_iceberg
    ,CASE WHEN SOS_COLUMNS IS NOT NULL THEN ''SEARCH OPTIMIZATION'' 
        ELSE table_etl.table_type
        END AS table_type
    ,table_etl.is_transient
    ,table_etl.auto_clustering_on
    ,table_etl.CLUSTER_BY_KEYS
    ,sc.SOS_COLUMNS
    ,sos_table_etl.name as sos_table_name
    ,sos_table_etl.cluster_by_keys as sos_cluster_by_keys
    ,COALESCE(sos_table_name, table_etl.name) as cleansed_table_name
    ,CASE WHEN COALESCE(SOS_CLUSTER_BY_KEYS,table_etl.cluster_by_keys) = ''LINEAR(EXPRESSION_ID, LEVEL, BLOCK_ID)''
    THEN NULL 
    ELSE COALESCE(SOS_CLUSTER_BY_KEYS,table_etl.cluster_by_keys) END as cleansed_cluster_by_keys
    ,sos_table_etl.auto_clustering_on as sos_clustering_on
    ,case when sos_cluster_by_keys IS NOT NULL THEN sos_clustering_on
    WHEN table_etl.CLUSTER_BY_KEYS = ''LINEAR(EXPRESSION_ID, LEVEL, BLOCK_ID)'' THEN ''NO''
    else table_etl.auto_clustering_on END as cleansed_auto_clustering_on
    ,table_etl.DATA_RETENTION_TIME_IN_DAYS
    FROM x_table_etl_v_stg table_etl
    LEFT JOIN SOS_COLUMNS sc
        on table_etl.id = sc.id
        and table_etl.account_id = sc.account_id
    LEFT JOIN x_table_etl_v_stg sos_table_etl
        on sos_table_etl.id::int = table_etl.mv_source_table_id
        and sos_table_etl.kind_id = 1
        and table_etl.kind_id = 8
        and table_etl.mv_type_id = 3
        and sos_table_etl.account_id = table_etl.account_id
    )
,x_schema_etl_v as (select dpo
    ,P.PARAMETER_VALUE as DATA_RETENTION_TIME_IN_DAYS
    from {t_schema_etl_v} as schema_etl
    JOIN {scoped_table} S 
        on schema_etl.dpo:"SchemaDPO:primary".accountId::int = S.account_id
        and S.deployment = ''{deployment}''
    LEFT JOIN x_parameters P
                                on schema_etl.account_id = P.account_id
                                and schema_etl.id = P.entity_id
                                and P.level = ''SCHEMA''
    where true),
x_database_etl_v as (select dpo 
    ,P.PARAMETER_VALUE as DATA_RETENTION_TIME_IN_DAYS
    from {t_database_etl_v} as database_etl
    JOIN {scoped_table} S 
        on database_etl.dpo:"DatabaseDPO:primary".accountId::int = S.account_id
        and S.deployment = ''{deployment}''
    LEFT JOIN x_parameters P
                                on database_etl.account_id = P.account_id
                                and database_etl.id = P.entity_id
                                and P.level = ''DATABASE''
    where true
    and database_etl.dpo:"DatabaseDPO:primary".tempId::int = 0)

                            select
                           coalesce(accounting.account_id,table_etl.account_id) as account_id
                          ,''{deployment}''                               as deployment
                          , coalesce(table_etl.id, accounting.table_id)::int as id
                          , iff(nvl(table_etl.mv_type_id, 0) = 3,
                                concat(''SEARCH OPTIMIZATION ON TABLE_ID:'', (table_etl.mv_source_table_id)),
                                table_etl.name) as table_name
                          , table_etl.cleansed_table_name as cleansed_table_name
                          , (schema_etl.dpo:"SchemaDPO:primary":id::int) as table_schema_id
                          , schema_etl.dpo:"SchemaDPO:primary":name::string as table_schema
                          , (database_etl.dpo:"DatabaseDPO:primary":id::int) as table_catalog_id
                          , database_etl.dpo:"DatabaseDPO:primary":name::string as table_catalog
                          , (coalesce(table_etl.source_id, accounting.table_source_id))::int clone_group_id
                          , table_etl.is_transient
                          , table_etl.is_iceberg
                          , table_etl.cleansed_auto_clustering_on as auto_clustering_on
                          , table_etl.cleansed_cluster_by_keys as CLUSTER_BY_KEYS
                          , table_etl.SOS_COLUMNS
                          , coalesce(accounting.stats[3]::number, 0) as active_bytes
                          , coalesce(accounting.stats[4]::number, 0) as time_travel_bytes
                          , case when deleted = true then 0
                            else coalesce(accounting.stats[6]::number, 0)
                            end as failsafe_bytes
                          , coalesce(accounting.stats[5]::number, 0) as retained_for_clone_bytes
                          , case when table_etl.deleted_on is not null then true
                                 when table_etl.expired_time is not null then true
                                 else false
                            end as deleted
                          , COALESCE(table_etl.DATA_RETENTION_TIME_IN_DAYS, schema_etl.DATA_RETENTION_TIME_IN_DAYS, database_etl.DATA_RETENTION_TIME_IN_DAYS, P.PARAMETER_VALUE,
                          1 //Default is 1 day
                          )::int as DATA_RETENTION_TIME_IN_DAYS
                          , table_etl.table_type
                          , table_etl.created_on::timestamp_ltz as table_created
                          , table_etl.deleted_on::timestamp_ltz as table_dropped
                          , case
                            when (
                                table_etl.iceberg_table_type_id is not null
                                and table_etl.iceberg_table_type_id > 0
                            ) then null
                            else table_etl.expired_time::timestamp_ltz
                            end as table_entered_failsafe
                          , (schema_etl.dpo:"SchemaDPO:primary":createdOn::int/1000)::timestamp_ltz as schema_created
                          , (schema_etl.dpo:"SchemaDPO:primary":deletedOn::int/1000)::timestamp_ltz as schema_dropped
                          , (database_etl.dpo:"DatabaseDPO:primary":createdOn::int/1000)::timestamp_ltz as catalog_created
                          , (database_etl.dpo:"DatabaseDPO:primary":deletedOn::int/1000)::timestamp_ltz as catalog_dropped
                          , table_etl.comment as comment
                        from  x_accounting as accounting
                        full outer join x_table_etl_v as table_etl
                        on accounting.table_id::int = table_etl.id
                        and accounting.account_id = table_etl.account_id
                        left join x_schema_etl_v as schema_etl
                        on table_etl.parent_id = schema_etl.dpo:"SchemaDPO:primary":id::int
                        and accounting.account_id = schema_etl.dpo:"SchemaDPO:primary".accountId::int
                        left join x_database_etl_v as database_etl
                        on schema_etl.dpo:"SchemaDPO:primary":parentId::int = database_etl.dpo:"DatabaseDPO:primary":id::int
                        and accounting.account_id = database_etl.dpo:"DatabaseDPO:primary".accountId::int
                        left join x_parameters P
                            on P.account_id = table_etl.account_id
                            and P.level = ''ACCOUNT''
                        where true
                        and database_etl.dpo:"DatabaseDPO:primary".tempId::int = 0
                        )
                        );
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
