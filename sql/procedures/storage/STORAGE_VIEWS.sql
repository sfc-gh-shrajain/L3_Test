CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.STORAGE_VIEWS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'warehouse_views'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def warehouse_views(session,cust_name: str):
    try:
        # Define and set variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''

        # Days in Month
        days_in_previous_month = session.sql("SELECT DAY(DATEADD(''day'',-1, DATE_TRUNC(''month'',CURRENT_DATE())))").collect()[0][0]

        # Set table variables
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        table_overview = f''{schema}.TABLE_OVERVIEW''
        table_storage_metrics = f''{schema}.TABLE_STORAGE_METRICS''
        tables2 = f''{schema}.TABLES2''
        unused_active_storage = f''{schema}.UNUSED_ACTIVE_STORAGE''
        access_history = f''{schema}.ACCESS_HISTORY''
        large_inactive_storage = f''{schema}.INACTIVE_STORAGE_LT''
        account_storage_overview = f''{schema}.ACCOUNT_STORAGE_OVERVIEW''
        accounts = f''{schema}.SFDC_ACCOUNTS''
        cost_table = f''{schema}.COST_TABLE''
        storage_account_agg = f''{schema}.STORAGE_ACCOUNT_AGG''
        auto_cluster_analysis = f''{schema}.AUTO_CLUSTER_ANALYSIS''
        
        # Create Tables_Overview VIEW logic
        TABLES_OVERVIEW_CVA = f"""
            CREATE OR REPLACE VIEW {table_overview} AS (
            WITH TABLE_SHARES AS (
            SELECT 
            cs.account_id
            ,cs.deployment
            ,cs.securable_id as table_id
            ,cs.SECURABLE_DETAILS:kind_id as table_kind
            ,CASE WHEN table_kind <> 1 THEN ''NON_TABLE'' ELSE ''TABLE'' END as table_type
            ,COUNT(*) as num_shares
             FROM SNOWSCIENCE.DATA_SHARING.CURRENT_SHARE_CONTENTS cs
             JOIN {scoped_table} S
             //FINOPS.NTT_PROD_250122.SCOPED_ACCOUNTS S
                on S.account_id = cs.account_id
                and S.deployment = cs.deployment
            WHERE true
            and securable_type = ''T''
            GROUP BY ALL
            //and deployment = ''awsapnortheast1'' and account_id = 5681
            //and NAME NOT IN (''SNOWFLAKE'',''SNOWFLAKE_SAMPLE_DATA'')
            )
            SELECT 
            tsm.account_id
            ,tsm.deployment
            ,tsm.id as table_id
            ,tsm.table_name
            ,tsm.table_schema_id
            ,tsm.table_schema
            ,tsm.table_catalog_id
            ,tsm.table_catalog
            ,tsm.clone_group_id
            ,tsm.is_transient
            ,tsm.is_iceberg
            ,tsm.active_bytes
            ,tsm.time_travel_bytes
            ,tsm.failsafe_bytes
            ,tsm.retained_for_clone_bytes
            ,tsm.deleted
            ,tsm.data_retention_time_in_days
            ,tsm.table_created
            ,tsm.table_dropped
            ,tsm.table_entered_failsafe
            ,tsm.schema_created
            ,tsm.schema_dropped
            ,tsm.catalog_created
            ,tsm.catalog_dropped
            ,tsm.comment
            ,tsm.cluster_by_keys as clustering_keys
            ,tsm.auto_clustering_on
            ,tsm.SOS_COLUMNS
            ,tsm.table_type
            ,concat(TABLE_CATALOG, ''.'',TABLE_SCHEMA, ''.'',tsm.CLEANSED_TABLE_NAME) as full_table_name
            ,(ACTIVE_BYTES+TIME_TRAVEL_BYTES+FAILSAFE_BYTES+RETAINED_FOR_CLONE_BYTES)/power(1024, 4) table_size_tb
            ,(TIME_TRAVEL_BYTES+FAILSAFE_BYTES)/power(1024, 4) as inactive_size_tb
            ,(ACTIVE_BYTES+RETAINED_FOR_CLONE_BYTES)/power(1024, 4) as total_active_size_tb
            ,timediff(''hour'',tsm.table_created,tsm.table_dropped) as table_life_duration_hours
            ,CASE WHEN TABLE_SIZE_TB > 0.1 THEN ''LARGE'' ELSE ''SMALL'' END AS TABLE_SIZE
            ,IFNULL((CASE WHEN failsafe_bytes > 0 THEN DIV0(((failsafe_bytes/pow(1024,4))/7),total_active_size_tb)
                WHEN time_travel_bytes > 0 THEN DIV0(DIV0((time_travel_bytes/pow(1024,4)),(CASE WHEN IFNULL(data_retention_time_in_days,0) = 0 then 1 //Handles the case of transient table with time travel
                                                                                                                    else data_retention_time_in_days END)),total_active_size_tb)
                ELSE 0
                END * 100),0) * 30.5 //average days in a month
                AS churn_pct
            ,div0(((TIME_TRAVEL_BYTES+FAILSAFE_BYTES)/pow(1024,4)),total_active_size_tb)*100 as inactive_storage_pct
            ,nvl(ts.num_shares,0) as num_shares
            FROM 
                {tables2} t2
                //FINOPS.NTT_PROD_250122.tables2 t2
            join 
                {table_storage_metrics} tsm  
            // FINOPS.NTT_PROD_250122.table_storage_metrics tsm
                on t2.account_id = tsm.account_id
                and t2.deployment = tsm.deployment
                and t2.table_id = tsm.id
            LEFT OUTER join TABLE_SHARES ts 
                on ts.account_id = t2.account_id
                and ts.deployment = t2.deployment
                and ts.table_id = t2.table_id 
            WHERE true 
            )
            ;
        """
        
        # Create Unused Active Storage VIEW logic
        UNUSED_ACTIVE_STORAGE_CVA = f"""
        CREATE OR REPLACE VIEW {unused_active_storage} AS (
         WITH tables_names as (
         SELECT DISTINCT
            account_id
            ,deployment
            ,table_catalog
            ,table_schema
            ,cleansed_table_name
        FROM 
        {table_storage_metrics}
        // FINOPS_OUTPUTS.ENGAGE3_FINOPS_20250506.TABLE_STORAGE_METRICS tsm
        WHERE 1 = 1
        and deleted = false 
        and table_entered_failsafe Is null
        and table_type != ''LOCAL TEMPORARY''
         )
         ,AUTO_CLUSTER AS 
        (
        SELECT aca.*
        , tsm.cleansed_table_name
        FROM 
         {auto_cluster_analysis} aca
        // FINOPS_OUTPUTS.ENGAGE3_FINOPS_20250506.AUTO_CLUSTER_ANALYSIS aca
        LEFT JOIN tables_names tsm
            on tsm.account_id = aca.account_id
            and tsm.deployment = aca.deployment
            and tsm.table_catalog = aca.database_name
            and tsm.table_schema = aca.schema_name
            and tsm.cleansed_table_name = aca.table_name
        )
        ,BASE_TABLES AS (
        select
        a.ACCOUNT_ID,
        a.deployment,
        TABLE_SIZE, 
        a.table_type,
        a.FULL_TABLE_NAME, 
        AUTO_CLUSTERING_ON,
        SUM(accesses) as Table_Accesses, 
        COALESCE(SUM(ACTIVE_BYTES)/power(1024, 4),0) + COALESCE(SUM(RETAINED_FOR_CLONE_BYTES)/power(1024, 4),0) as ACTIVE_TB,
        SUM(TABLE_SIZE_TB) AS TB,
        service_level
        from 
        {table_overview} a 
        //FINOPS_OUTPUTS.ENGAGE3_FINOPS_20250506.table_overview a 
        left join (select 
                    table_name 
                    ,SUM(NUMBER_OF_ACCESSES) as accesses 
                   from 
                   {access_history} 
                   // FINOPS_OUTPUTS.ENGAGE3_FINOPS_20250506.ACCESS_HISTORY
                   GROUP BY ALL
                   ) b 
            on a.full_table_name = b.table_name
        left join 
         {accounts} acc
        //FINOPS_OUTPUTS.ENGAGE3_FINOPS_20250506.SFDC_ACCOUNTS acc
            on acc.snowflake_account_id = a.account_id
            and acc.snowflake_deployment = a.deployment
       
        WHERE 1=1
        and a.deleted = FALSE //only active tables
        and a.table_entered_failsafe IS NULL //no expired tables
        and a.is_iceberg = ''NO''
        and a.num_shares = 0 //ensures it doesn''t count tables that are in shares (assumes the shares are being used)
        AND b.table_name is null
        AND a.table_type != ''LOCAL TEMPORARY'' //remove temporary tables
        GROUP BY ALL
        ) 
        
        SELECT
        a.ACCOUNT_ID,
        a.deployment,
        TABLE_SIZE, 
        FULL_TABLE_NAME, 
        AUTO_CLUSTERING_ON,
        Table_Accesses, 
        ACTIVE_TB,
        TB,
        SUM(aca.TOTAL_RECLUSTER_CREDITS) as recluster_credits
        from BASE_TABLES a
        left join AUTO_CLUSTER aca
            on a.account_id = aca.account_id
            and a.deployment = aca.deployment
            and a.full_table_name = (aca.DATABASE_NAME || ''.'' || aca.schema_name || ''.'' || aca.cleansed_table_name)
        WHERE 1 = 1 
        AND (
            (TB >= 0.1 and service_level IN (''ENTERPRISE'',''BUSINESS_CRITICAL'',''VPS'')) 
            OR 
            aca.TOTAL_RECLUSTER_CREDITS > 5
            )
        GROUP BY ALL
        order by TB desc
          )
          ;
            """
    # Create Large Inactive Storage VIEW logic
        LARGE_INACTIVE_STORAGE_CVA = f"""
        CREATE OR REPLACE VIEW {large_inactive_storage} AS (
        SELECT
            t.ACCOUNT_ID
            ,t.deployment
            ,full_table_name
            ,TABLE_SIZE
            ,t.active_bytes/power(1024,4) as active_size_tb
            ,t.time_travel_bytes/power(1024,4) as time_travel_tb
            ,t.failsafe_bytes/power(1024,4) as failsafe_tb
            ,t.retained_for_clone_bytes/power(1024,4) as clone_retain_tb
            ,table_size_tb
            ,inactive_size_tb
            ,churn_pct
            ,inactive_storage_pct
//            ,t.deleted
            ,t.data_retention_time_in_days
        FROM
            {table_overview} t
        WHERE 1=1
        AND deleted = FALSE 
        and table_entered_failsafe IS NULL //ensures no failsafe but not yet deleted tables
        AND (
            (churn_pct >=40) //40% churn within a month of the entire table
            OR inactive_storage_pct >= 40 //40% of the table size is in inactive storage
            )
        and inactive_size_tb > 0.1
        and is_iceberg = ''NO''
        and table_type != ''LOCAL TEMPORARY''
        ORDER BY table_size_tb desc
        )
        ;
            """
    # Create Account Storage Overview logic
        ACCOUNT_STORAGE_OVERVIEW_CVA = f"""
        CREATE OR REPLACE VIEW {account_storage_overview} AS (
        select
        ACCOUNT_ID
        ,DEPLOYMENT
        ,SUM(ACTIVE_BYTES)/power(1024, 4) as ACTIVE_TB
        ,SUM(INACTIVE_SIZE_TB) AS INACTIVE_TB
        ,SUM(time_travel_bytes)/power(1024,4) as TIME_TRAVEL_TB 
        ,SUM(failsafe_bytes)/power(1024,4) as FAILSAFE_TB
        ,SUM(RETAINED_FOR_CLONE_BYTES)/power(1024,4) as RETAINED_FOR_CLONE_TB
        ,SUM(TABLE_SIZE_TB) as TOTAL_STORAGE_TB
        ,SUM(total_active_size_tb)/TOTAL_STORAGE_TB*100 as ACTIVE_PERCENTAGE
        ,INACTIVE_TB/TOTAL_STORAGE_TB*100 as INACTIVE_PERCENTAGE
        from {table_overview} a 
        WHERE 1=1
        and deleted = false //only active tables
        and table_type != ''LOCAL TEMPORARY'' //only permanent or transient tables
        and is_iceberg = ''NO'' //remove iceberg tables from consideration
        GROUP BY ALL
          )
        ;
            """

    # Create Aggregate Account Storage Overview logic
        STORAGE_ACCOUNT_AGG_CVA = f"""            
        CREATE OR REPLACE VIEW {storage_account_agg} AS (
        //inactive storage
        WITH INACTIVE_STORAGE AS (
        SELECT 
        t.account_id
        ,t.deployment
        ,SUM(inactive_size_tb) as total_inactive_tb
        FROM {large_inactive_storage} t
        GROUP BY ALL)
        ,
        UNUSED_STORAGE AS (
        SELECT 
        t.account_id
        ,t.deployment
        ,SUM(active_tb) as total_unused_tb
        ,SUM(recluster_credits) as total_recluster_credits
        FROM {unused_active_storage} t
        GROUP BY ALL
        )
        SELECT 
        a.account_id
        ,a.deployment
        ,a.locator
        ,a.account_name
        ,u.total_unused_tb
        ,IFNULL(total_unused_tb*c.storage_price*(365/{days_in_previous_month}),0) as unused_storage_annualized_savings_dollars
        ,total_recluster_credits*(365/{days_in_previous_month}) as unused_autocluster_annualized_credits
        ,IFNULL(unused_autocluster_annualized_credits*c.price_per_credit,0) as unused_storage_autocluster_annualized_savings_dollars
        ,total_inactive_tb
        ,IFNULL(total_inactive_tb*c.storage_price*(365/{days_in_previous_month}),0) as inactive_storage_annualized_savings_dollars
        from {scoped_table} a
        LEFT JOIN {cost_table} c
        on c.account_id = a.account_id
        and c.deployment = a.deployment
        LEFT JOIN UNUSED_STORAGE u
        on u.account_id = a.account_id
        and u.deployment = a.deployment
        LEFT JOIN INACTIVE_STORAGE i
        on i.account_id = a.account_id
        and i.deployment = a.deployment
        )
        ;
        """
         
        # Execute the view queries
        session.sql(TABLES_OVERVIEW_CVA).collect()
        session.sql(UNUSED_ACTIVE_STORAGE_CVA).collect()
        session.sql(LARGE_INACTIVE_STORAGE_CVA).collect()
        session.sql(ACCOUNT_STORAGE_OVERVIEW_CVA).collect()
        session.sql(STORAGE_ACCOUNT_AGG_CVA).collect()
        
        return ''Views created successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
