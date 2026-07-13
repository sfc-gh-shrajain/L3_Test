CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.TOTAL_ACCOUNT_SAVINGS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'total_account_sav'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def total_account_sav(session, cust_name: str):
    try:
        # define variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        billing_table = f''{schema}.BILLING''
        cost_table = f''{schema}.COST_TABLE''
        query_agg = f''{schema}.QUERY_ACCOUNT_AGG''
        savings_adjustments = f''{schema}.SAVINGS_ADJUSTMENTS''
        total_account_savings = f''{schema}.TOTAL_ACCOUNT_SAVINGS''
        account_rocks_savings = f''{schema}.ACCOUNT_ROCKS_SAVINGS''
        savings_account_contextualization = f''{schema}.SAVINGS_ACCOUNT_CONTEXTUALIZATION''
        scoped_accounts_rocks_summary = f''{schema}.SCOPED_ACCOUNTS_ROCKS_SUMMARY''
        warehouse_account_agg = f''{schema}.WAREHOUSE_ACCOUNT_AGG''
        storage_account_agg = f''{schema}.STORAGE_ACCOUNT_AGG''
        query_account_agg = f''{schema}.QUERY_ACCOUNT_AGG''
        other_account_agg = f''{schema}.OTHER_ACCOUNT_AGG''

        # End of Previous Month
        previous_month_start = session.sql("SELECT DATE_TRUNC(''month'',DATEADD(''month'',-1,CURRENT_DATE()))").collect()[0][0]
        previous_month_start = previous_month_start.strftime(''%Y-%m-%d'')

        # Days in Month
        days_in_previous_month = session.sql("SELECT DAY(DATEADD(''day'',-1, DATE_TRUNC(''month'',CURRENT_DATE())))").collect()[0][0]

# Create Query Aggregate View
        SAVINGS_ADJUSTMENTS_CVA = f"""
        CREATE OR REPLACE VIEW {savings_adjustments} AS (
        WITH MANUALLY_SET AS (
        SELECT 
         30 as low_warehouse_sizing
        ,50 as high_warehouse_sizing
        ,30 as low_warehouse_consolidation
        ,50 as high_warehouse_consolidation
        ,40 as low_warehouse_timeout
        ,40 as high_warehouse_timeout
        ,20 as low_erroring_queries
        ,30 as high_erroring_queries
        ,10 as low_repeated_queries
        ,20 as high_repeated_queries
        ,30 as low_unused_storage
        ,50 as high_unused_storage
        ,50 as low_inactive_storage
        ,70 as high_inactive_storage
        ,20 as low_copy_ingest
        ,30 as high_copy_ingest
        ,40 as low_snowpipe_ingest
        ,50 as high_snowpipe_ingest
        ,20 as low_autoclustering
        ,30 as high_autoclustering
        ,80 as low_unused_autoclustering
        ,100 as high_unused_autoclustering
        ,60 as low_autosuspend
        ,80 as high_autosuspend
        ,70 as low_cloudservices
        ,100 as high_cloudservices
        FROM DUAL
        )
        
        SELECT 
          low_warehouse_sizing
        ,high_warehouse_sizing
        ,low_warehouse_consolidation
        ,high_warehouse_consolidation
        ,low_warehouse_timeout
        ,high_warehouse_timeout
        ,low_erroring_queries
        ,high_erroring_queries
        ,low_repeated_queries
        ,high_repeated_queries
        ,low_unused_storage
        ,high_unused_storage
        ,low_inactive_storage
        ,high_inactive_storage
        ,low_copy_ingest
        ,high_copy_ingest
        ,low_snowpipe_ingest
        ,high_snowpipe_ingest
        ,low_autoclustering
        ,high_autoclustering
        ,low_unused_autoclustering
        ,high_unused_autoclustering
        //unused SOS should match unused autocluster as a default
        ,low_unused_autoclustering as low_unused_search_indexes
        ,high_unused_autoclustering as high_unused_search_indexes
        ,low_warehouse_consolidation as low_warehouse_idle_time
        ,high_warehouse_consolidation as high_warehouse_idle_time
        ,low_autosuspend
        ,high_autosuspend
        ,low_cloudservices
        ,high_cloudservices
        FROM MANUALLY_SET
        )
        ;
        """

    # Create Total Account Savings View
        # This can be deleted after validating the new excel template. (1.3.25)
        
        TOTAL_ACCOUNT_AGG_CVA = f"""
        CREATE OR REPLACE VIEW {total_account_savings} AS (
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name

            //warehouse consolidation
            ,ROUND(IFNULL(w.low_concurrency_annualized_dollar_savings * p.low_warehouse_consolidation/100,0),2) as low_warehouse_consolidation_dollar_savings
            ,ROUND(IFNULL(w.high_concurrency_annualized_dollar_savings * p.high_warehouse_consolidation/100,0),2) as high_warehouse_consolidation_dollar_savings

            //warehouse sizing
            ,ROUND(IFNULL(w.low_sizing_annualized_dollar_savings * p.low_warehouse_sizing/100,0),2) as  low_warehouse_sizing_dollar_savings
            ,ROUND(IFNULL(w.high_sizing_annualized_dollar_savings * p.high_warehouse_sizing/100,0),2) as  high_warehouse_sizing_dollar_savings

            //warehouse timeout
            ,ROUND(IFNULL(w.low_timeout_annualized_dollar_savings * p.low_warehouse_timeout/100,0),2) as low_warehouse_timeout_dollar_savings
            ,ROUND(IFNULL(w.high_timeout_annualized_dollar_savings * p.high_warehouse_timeout/100,0),2) as high_warehouse_timeout_dollar_savings

            //inactive storage
            ,ROUND(IFNULL(s.inactive_storage_annualized_savings_dollars * p.low_inactive_storage/100,0),2) as low_inactive_storage_annualized_savings_dollars
            ,ROUND(IFNULL(s.inactive_storage_annualized_savings_dollars * p.high_inactive_storage/100,0),2) as high_inactive_storage_annualized_savings_dollars

            //unused storage
            ,ROUND(IFNULL(s.unused_storage_annualized_savings_dollars * p.low_unused_storage/100,0),2) as low_unused_storage_annualized_savings_dollars
            ,ROUND(IFNULL(s.unused_storage_annualized_savings_dollars * p.high_unused_storage/100,0),2) as high_unused_storage_annualized_savings_dollars

            //unused storage autocluster
            ,ROUND(IFNULL(s.unused_storage_autocluster_annualized_savings_dollars * p.low_unused_autoclustering/100,0),2) as low_unused_autocluster_annualized_savings_dollars
            ,ROUND(IFNULL(s.unused_storage_autocluster_annualized_savings_dollars * p.high_unused_autoclustering/100,0),2) as high_unused_autocluster_annualized_savings_dollars

            //query errors
            ,ROUND(IFNULL(q.error_savings_dollars * p.low_erroring_queries/100,0),2) as low_erroring_queries_annualized_dollar_savings
            ,ROUND(IFNULL(q.error_savings_dollars * p.high_erroring_queries/100,0),2) as high_erroring_queries_annualized_dollar_savings

            //repeated queries
            ,ROUND(IFNULL(q.repeated_queries_savings_dollars * p.low_repeated_queries/100,0),2) as low_repeated_queries_annualized_dollar_savings
            ,ROUND(IFNULL(q.repeated_queries_savings_dollars * p.high_repeated_queries/100,0),2) as high_repeated_queries_annualized_dollar_savings

            //copy ingest
            ,ROUND(IFNULL(q.low_copy_dollar_savings * p.low_copy_ingest/100,0),2) as low_copy_annualized_dollar_savings
            ,ROUND(IFNULL(q.high_copy_dollar_savings * p.high_copy_ingest/100,0),2) as high_copy_annualized_dollar_savings

            //snowpipe
            ,ROUND(IFNULL(o.LOW_SNOWPIPE_ANNUAL_DOLLAR_SAVINGS * p.low_snowpipe_ingest/100,0),2) as low_snowpipe_annualized_dollar_savings
            ,ROUND(IFNULL(o.HIGH_SNOWPIPE_ANNUAL_DOLLAR_SAVINGS * p.high_snowpipe_ingest/100,0),2) as high_snowpipe_annualized_dollar_savings

            //autocluster
            ,ROUND(IFNULL(o.LOW_AUTOCLUSTER_ANNUAL_DOLLAR_SAVINGS * p.low_autoclustering/100,0),2) as low_autocluster_annualized_dollar_savings
            ,ROUND(IFNULL(o.HIGH_AUTOCLUSTER_ANNUAL_DOLLAR_SAVINGS * p.high_autoclustering/100,0),2) as high_autocluster_annualized_dollar_savings

            //autosuspend
            ,ROUND(IFNULL(w.low_autosuspend_annualized_dollar_savings * p.low_autosuspend/100,0),2) as low_autosuspend_dollar_savings
            ,ROUND(IFNULL(w.high_autosuspend_annualized_dollar_savings * p.high_autosuspend/100,0),2) as high_autosuspend_dollar_savings  

            //cloud services
            ,ROUND(IFNULL(o.LOW_CLOUD_SERVICES_ANNUAL_DOLLAR_SAVINGS * p.low_cloudservices/100,0),2) as low_cloud_services_annualized_dollar_savings
            ,ROUND(IFNULL(o.HIGH_CLOUD_SERVICES_ANNUAL_DOLLAR_SAVINGS * p.high_cloudservices/100,0),2) as high_cloud_services_annualized_dollar_savings

            //totals
            ,low_warehouse_consolidation_dollar_savings + low_warehouse_sizing_dollar_savings + low_warehouse_timeout_dollar_savings + low_inactive_storage_annualized_savings_dollars + low_unused_storage_annualized_savings_dollars + low_erroring_queries_annualized_dollar_savings + low_repeated_queries_annualized_dollar_savings + low_copy_annualized_dollar_savings + low_snowpipe_annualized_dollar_savings + low_autocluster_annualized_dollar_savings + low_unused_autocluster_annualized_savings_dollars + low_autosuspend_dollar_savings + low_cloud_services_annualized_dollar_savings
            as total_low_annualized_dollar_savings
            ,high_warehouse_consolidation_dollar_savings + high_warehouse_sizing_dollar_savings + high_warehouse_timeout_dollar_savings + high_inactive_storage_annualized_savings_dollars + high_unused_storage_annualized_savings_dollars + high_erroring_queries_annualized_dollar_savings + high_repeated_queries_annualized_dollar_savings + high_copy_annualized_dollar_savings + high_snowpipe_annualized_dollar_savings + high_autocluster_annualized_dollar_savings + high_unused_autocluster_annualized_savings_dollars + high_autosuspend_dollar_savings + 
            high_cloud_services_annualized_dollar_savings
            as total_high_annualized_dollar_savings
        FROM {scoped_table} a
        CROSS JOIN {savings_adjustments} p
        LEFT JOIN {warehouse_account_agg} w
            on a.account_id = w.account_id
            and a.deployment = w.deployment
        LEFT JOIN {storage_account_agg} s
            on a.account_id = s.account_id
            and a.deployment = s.deployment
        LEFT JOIN {query_account_agg} q
            on a.account_id = q.account_id
            and a.deployment = q.deployment
        LEFT JOIN {other_account_agg} o
            on a.account_id = o.account_id
            and a.deployment = o.deployment
        )
        ;
        """

    # Create Account Rocks Savings View
        ACCOUNT_ROCKS_AGG_CVA = f"""
    CREATE OR REPLACE VIEW {account_rocks_savings} AS (
 //CREATE OR REPLACE VIEW FINOPS.SIEMENS_AG.ACCOUNT_ROCKS_SAVINGS AS (
 
        //Warehouse Consolidation
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''COMPUTE'' as revenue_group
            ,''WAREHOUSE'' as rock_category
            ,''WAREHOUSE_CONSOLIDATION'' as rock
            ,p.low_warehouse_consolidation as low_applied_adj_percentage
            ,p.high_warehouse_consolidation as high_applied_adj_percentage
            ,ROUND(IFNULL(w.low_concurrency_annualized_credit_savings * p.low_warehouse_consolidation/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(w.high_concurrency_annualized_credit_savings * p.high_warehouse_consolidation/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(w.low_concurrency_annualized_dollar_savings * p.low_warehouse_consolidation/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(w.high_concurrency_annualized_dollar_savings * p.high_warehouse_consolidation/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.WAREHOUSE_ACCOUNT_AGG w
        {warehouse_account_agg} w
            on a.account_id = w.account_id
            and a.deployment = w.deployment

        UNION ALL
        
         //Warehouse Idle Time (In Beta)
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''COMPUTE'' as revenue_group
            ,''WAREHOUSE'' as rock_category
            ,''WAREHOUSE_IDLE_TIME'' as rock
            ,p.low_warehouse_idle_time as low_applied_adj_percentage
            ,p.high_warehouse_idle_time as high_applied_adj_percentage
            ,ROUND(IFNULL(w.low_idle_time_annualized_credit_savings * p.low_warehouse_idle_time/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(w.high_idle_time_annualized_credit_savings * p.high_warehouse_idle_time/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(w.low_idle_time_annualized_dollar_savings * p.low_warehouse_idle_time/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(w.high_idle_time_annualized_dollar_savings * p.high_warehouse_idle_time/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.WAREHOUSE_ACCOUNT_AGG w
        {warehouse_account_agg} w
            on a.account_id = w.account_id
            and a.deployment = w.deployment

        UNION ALL
        
        //Warehouse Sizing
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''COMPUTE'' as revenue_group
            ,''WAREHOUSE'' as rock_category
            ,''WAREHOUSE_SIZING'' as rock
            ,p.low_warehouse_sizing as low_applied_adj_percentage
            ,p.high_warehouse_sizing as high_applied_adj_percentage
            ,ROUND(IFNULL(w.low_sizing_annualized_credit_savings * p.low_warehouse_sizing/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(w.high_sizing_annualized_credit_savings * p.high_warehouse_sizing/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(w.low_sizing_annualized_dollar_savings * p.low_warehouse_sizing/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(w.high_sizing_annualized_dollar_savings * p.high_warehouse_sizing/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.WAREHOUSE_ACCOUNT_AGG w
        {warehouse_account_agg} w
            on a.account_id = w.account_id
            and a.deployment = w.deployment
            
        UNION ALL
        
        //Warehouse Timeout
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''COMPUTE'' as revenue_group
            ,''WAREHOUSE'' as rock_category
            ,''WAREHOUSE_TIMEOUT'' as rock
            ,p.low_warehouse_timeout as low_applied_adj_percentage
            ,p.high_warehouse_timeout as high_applied_adj_percentage
            ,ROUND(IFNULL(w.low_timeout_annualized_credit_savings * p.low_warehouse_timeout/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(w.high_timeout_annualized_credit_savings * p.high_warehouse_timeout/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(w.low_timeout_annualized_dollar_savings * p.low_warehouse_timeout/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(w.high_timeout_annualized_dollar_savings * p.high_warehouse_timeout/100,0),2) as high_annualized_dollar_savings 
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.WAREHOUSE_ACCOUNT_AGG w
        {warehouse_account_agg} w
            on a.account_id = w.account_id
            and a.deployment = w.deployment

        UNION ALL
        
        //Inactive Storage
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''STORAGE'' as revenue_group
            ,''STORAGE'' as rock_category
            ,''INACTIVE_STORAGE'' as rock
            ,p.low_inactive_storage as low_applied_adj_percentage
            ,p.high_inactive_storage as high_applied_adj_percentage
            ,NULL as low_annualized_credit_savings
            ,NULL as high_annualized_credit_savings
            ,ROUND(IFNULL(s.total_inactive_tb * p.low_inactive_storage/100,0),2) as low_annualized_tb_savings
            ,ROUND(IFNULL(s.total_inactive_tb * p.high_inactive_storage/100,0),2) as high_annualized_tb_savings
            ,ROUND(IFNULL(s.inactive_storage_annualized_savings_dollars * p.low_inactive_storage/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(s.inactive_storage_annualized_savings_dollars * p.high_inactive_storage/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.STORAGE_ACCOUNT_AGG s
        {storage_account_agg} s
            on a.account_id = s.account_id
            and a.deployment = s.deployment
            
        UNION ALL
        
        //Unused Storage
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''STORAGE'' as revenue_group
            ,''STORAGE'' as rock_category
            ,''UNUSED_STORAGE'' as rock
            ,p.low_unused_storage as low_applied_adj_percentage
            ,p.high_unused_storage as high_applied_adj_percentage
            ,NULL as low_annualized_credit_savings
            ,NULL as high_annualized_credit_savings
            ,ROUND(IFNULL(s.total_unused_tb * p.low_unused_storage/100,0),2) as low_annualized_tb_savings
            ,ROUND(IFNULL(s.total_unused_tb * p.high_unused_storage/100,0),2) as high_annualized_tb_savings
            ,ROUND(IFNULL(s.unused_storage_annualized_savings_dollars * p.low_unused_storage/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(s.unused_storage_annualized_savings_dollars * p.high_unused_storage/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.STORAGE_ACCOUNT_AGG s
        {storage_account_agg} s
            on a.account_id = s.account_id
            and a.deployment = s.deployment      

        UNION ALL
        
        //Unused Storage Autoclustering
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''OTHER'' as revenue_group
            ,''SERVERLESS'' as rock_category
            ,''UNUSED_STORAGE_AUTOCLUSTERING'' as rock
            ,p.low_unused_autoclustering as low_applied_adj_percentage
            ,p.high_unused_autoclustering as high_applied_adj_percentage
            ,ROUND(IFNULL(s.unused_autocluster_annualized_credits * p.low_unused_autoclustering/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(s.unused_autocluster_annualized_credits * p.high_unused_autoclustering/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(s.unused_storage_autocluster_annualized_savings_dollars * p.low_unused_autoclustering/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(s.unused_storage_autocluster_annualized_savings_dollars * p.high_unused_autoclustering/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.STORAGE_ACCOUNT_AGG s
        {storage_account_agg} s
            on a.account_id = s.account_id
            and a.deployment = s.deployment

        UNION ALL
        
        //Autoclustering
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''OTHER'' as revenue_group
            ,''SERVERLESS'' as rock_category
            ,''HIGH_CHURN_AUTOCLUSTERING'' as rock
            ,p.low_autoclustering as low_applied_adj_percentage
            ,p.high_autoclustering as high_applied_adj_percentage
            ,ROUND(IFNULL(o.low_autocluster_annual_credit_savings * p.low_autoclustering/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(o.high_autocluster_annual_credit_savings * p.high_autoclustering/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(o.low_autocluster_annual_dollar_savings * p.low_autoclustering/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(o.high_autocluster_annual_dollar_savings * p.high_autoclustering/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.OTHER_ACCOUNT_AGG o
        {other_account_agg} o
            on a.account_id = o.account_id
            and a.deployment = o.deployment
         
        UNION ALL
        
        //Snowpipe
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''OTHER'' as revenue_group
            ,''SERVERLESS'' as rock_category
            ,''SNOWPIPE'' as rock
            ,p.low_snowpipe_ingest as low_applied_adj_percentage
            ,p.high_snowpipe_ingest as high_applied_adj_percentage
            ,ROUND(IFNULL(o.low_snowpipe_annual_credit_savings * p.low_snowpipe_ingest/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(o.high_snowpipe_annual_credit_savings * p.high_snowpipe_ingest/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(o.low_snowpipe_annual_dollar_savings * p.low_snowpipe_ingest/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(o.high_snowpipe_annual_dollar_savings * p.high_snowpipe_ingest/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.OTHER_ACCOUNT_AGG o
        {other_account_agg} o
            on a.account_id = o.account_id
            and a.deployment = o.deployment

        UNION ALL
        
        //Erroring Queries
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''COMPUTE'' as revenue_group
            ,''QUERIES'' as rock_category
            ,''ERRORING_QUERIES'' as rock
            ,p.low_erroring_queries as low_applied_adj_percentage
            ,p.high_erroring_queries as high_applied_adj_percentage
            ,ROUND(IFNULL(q.error_credits_repeated * p.low_erroring_queries/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(q.error_credits_repeated * p.high_erroring_queries/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(q.error_savings_dollars * p.low_erroring_queries/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(q.error_savings_dollars * p.high_erroring_queries/100,0),2) as high_annualized_dollar_savings
         FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.QUERY_ACCOUNT_AGG q
        {query_account_agg} q
            on a.account_id = q.account_id
            and a.deployment = q.deployment

        UNION ALL
        
        //Repeated Queries
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''COMPUTE'' as revenue_group
            ,''QUERIES'' as rock_category
            ,''REPEATED_QUERIES'' as rock
            ,p.low_repeated_queries as low_applied_adj_percentage
            ,p.high_repeated_queries as high_applied_adj_percentage
            ,ROUND(IFNULL(q.repeated_queries_credits * p.low_repeated_queries/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(q.repeated_queries_credits * p.high_repeated_queries/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(q.repeated_queries_savings_dollars * p.low_repeated_queries/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(q.repeated_queries_savings_dollars * p.high_repeated_queries/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.QUERY_ACCOUNT_AGG q
        {query_account_agg} q
            on a.account_id = q.account_id
            and a.deployment = q.deployment

            UNION ALL
        
        //COPY INGEST
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''COMPUTE'' as revenue_group
            ,''INGEST'' as rock_category
            ,''COPY_INGEST'' as rock
            ,p.low_copy_ingest as low_applied_adj_percentage
            ,p.high_copy_ingest as high_applied_adj_percentage
            ,ROUND(IFNULL(q.low_copy_credit_savings * p.low_copy_ingest/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(q.high_copy_credit_savings * p.high_copy_ingest/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(q.low_copy_dollar_savings * p.low_copy_ingest/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(q.high_copy_dollar_savings * p.high_copy_ingest/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.QUERY_ACCOUNT_AGG q
        {query_account_agg} q
            on a.account_id = q.account_id
            and a.deployment = q.deployment  

        UNION ALL

        //Warehouse AutoSuspend
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''COMPUTE'' as revenue_group
            ,''WAREHOUSE'' as rock_category
            ,''WAREHOUSE_AUTOSUSPEND'' as rock
            ,p.low_autosuspend as low_applied_adj_percentage
            ,p.high_autosuspend as high_applied_adj_percentage
            ,ROUND(IFNULL(w.low_autosuspend_annualized_credit_savings * p.low_autosuspend/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(w.high_autosuspend_annualized_credit_savings * p.high_autosuspend/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(w.low_autosuspend_annualized_dollar_savings * p.low_autosuspend/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(w.high_autosuspend_annualized_dollar_savings * p.high_autosuspend/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.WAREHOUSE_ACCOUNT_AGG w
        {warehouse_account_agg} w
            on a.account_id = w.account_id
            and a.deployment = w.deployment

        UNION ALL
        
        //CLOUD SERVICES
        SELECT 
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,''OTHER'' as revenue_group
            ,''QUERIES'' as rock_category
            ,''CLOUD_SERVICES'' as rock
            ,p.low_cloudservices as low_applied_adj_percentage
            ,p.high_cloudservices as high_applied_adj_percentage
            ,ROUND(IFNULL(o.low_cloud_services_annual_credit_savings * p.low_cloudservices/100,0),2) as low_annualized_credit_savings
            ,ROUND(IFNULL(o.high_cloud_services_annual_credit_savings * p.high_cloudservices/100,0),2) as high_annualized_credit_savings
            ,NULL as low_annualized_tb_savings
            ,NULL as high_annualized_tb_savings
            ,ROUND(IFNULL(o.low_cloud_services_annual_dollar_savings * p.low_cloudservices/100,0),2) as low_annualized_dollar_savings
            ,ROUND(IFNULL(o.high_cloud_services_annual_dollar_savings * p.high_cloudservices/100,0),2) as high_annualized_dollar_savings
        FROM 
        //FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS a
        {scoped_table} a
        CROSS JOIN 
        //FINOPS.SIEMENS_AG.SAVINGS_ADJUSTMENTS p
        {savings_adjustments} p
        LEFT JOIN 
        //FINOPS.SIEMENS_AG.OTHER_ACCOUNT_AGG o
        {other_account_agg} o
            on a.account_id = o.account_id
            and a.deployment = o.deployment
        )
        ;
        """

    # Scoped Accounts Rocks Summary
        SCOPED_ACCOUNTS_ROCKS_SUMMARY_CVA = f"""
CREATE OR REPLACE VIEW {scoped_accounts_rocks_summary} AS (
//CREATE OR REPLACE VIEW FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS_ROCKS_SUMMARY AS (
    //Includes the Beta Warehouse Idle Time at this time.
        WITH ANNUALIZED_COST AS (
        SELECT  s.account_id
        , s.account_name
        , b.deployment
        , SUM(case when revenue_group = ''Compute'' THEN revenue else 0 end)*(365/{days_in_previous_month}) as COMPUTE_REVENUE
        , SUM(case when revenue_group = ''Storage'' THEN revenue else 0 end)*(365/{days_in_previous_month}) as STORAGE_REVENUE
        , SUM(case when revenue_group = ''Other'' THEN revenue else 0 end)*(365/{days_in_previous_month}) as OTHER_REVENUE
        , SUM(REVENUE)*(365/{days_in_previous_month}) as total_revenue
        , SUM(CREDITS)*(365/{days_in_previous_month}) as total_credits
        , SUM(STORAGE_TB)*(365/{days_in_previous_month}) as total_storage_tb
        FROM 
        -- FINOPS.SIEMENS_AG.BILLING b
        {billing_table} b
        JOIN 
        -- FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS s
        {scoped_table} s
            on s.account_id = b.account_id
            and s.deployment = b.deployment
        WHERE true
        -- and month = ''2024-11-01''
       and month = ''{previous_month_start}''
        GROUP BY ALL
        )
        ,BILLING_TOTALS
        AS (
        SELECT
        SUM(COMPUTE_REVENUE) AS COMPUTE_REVENUE
        , SUM(STORAGE_REVENUE) AS STORAGE_REVENUE
        , SUM(OTHER_REVENUE) AS OTHER_REVENUE
        , SUM(total_revenue) as total_revenue
        , SUM(total_credits) as total_credits
        , SUM(total_storage_tb) as total_storage_tb
        FROM ANNUALIZED_COST
        )
        
        SELECT
        REVENUE_GROUP
        ,ROCK_CATEGORY
        ,ROCK
        ,SUM(low_annualized_credit_savings) as total_low_annualized_credit_savings
        ,SUM(high_annualized_credit_savings) as total_high_annualized_credit_savings
        ,SUM(low_annualized_tb_savings) as total_low_annualized_tb_savings
        ,SUM(high_annualized_tb_savings) as total_high_annualized_tb_savings
        ,SUM(low_annualized_dollar_savings) as total_low_annualized_dollar_savings
        ,SUM(high_annualized_dollar_savings) as total_high_annualized_dollar_savings
        ,a.total_revenue
        ,a.total_credits
        ,a.total_storage_tb
        ,a.COMPUTE_REVENUE as TOTAL_COMPUTE_REVENUE
        ,a.STORAGE_REVENUE as TOTAL_STORAGE_REVENUE
        ,a.OTHER_REVENUE as TOTAL_OTHER_REVENUE
        ,CASE 
        WHEN REVENUE_GROUP = ''COMPUTE'' THEN DIV0(total_low_annualized_dollar_savings,TOTAL_COMPUTE_REVENUE) * 100
        WHEN REVENUE_GROUP = ''STORAGE'' THEN DIV0(total_low_annualized_dollar_savings,TOTAL_STORAGE_REVENUE) * 100
        WHEN REVENUE_GROUP = ''OTHER'' THEN DIV0(total_low_annualized_dollar_savings,TOTAL_OTHER_REVENUE) * 100
        ELSE NULL
        END AS low_revenue_category_percentage_savings
        ,CASE 
        WHEN REVENUE_GROUP = ''COMPUTE'' THEN DIV0(total_high_annualized_dollar_savings,TOTAL_COMPUTE_REVENUE) * 100
        WHEN REVENUE_GROUP = ''STORAGE'' THEN DIV0(total_high_annualized_dollar_savings,TOTAL_STORAGE_REVENUE) * 100
        WHEN REVENUE_GROUP = ''OTHER'' THEN DIV0(total_high_annualized_dollar_savings,TOTAL_OTHER_REVENUE) * 100
        ELSE NULL
        END AS high_revenue_category_percentage_savings
        FROM 
        -- FINOPS.SIEMENS_AG.ACCOUNT_ROCKS_SAVINGS t
        {account_rocks_savings} t
        CROSS JOIN BILLING_TOTALS a
        WHERE t.rock <> ''WAREHOUSE_IDLE_TIME'' //removes idle time until this is out of BETA.
        GROUP BY ALL
        order by TOTAL_HIGH_ANNUALIZED_DOLLAR_SAVINGS desc 
        )
        ;
        """
        
    # Account Savings Contextualization
        # This can be deleted after validating the new excel template. (1.3.25)
        
        SAVINGS_ACCOUNT_CONTEXTUALIZATION_CVA = f"""
        CREATE OR REPLACE VIEW {savings_account_contextualization} AS (
        WITH ANNUALIZED_COST AS (
        SELECT  s.account_id
        , s.account_name
        , b.deployment
        , SUM(case when revenue_group = ''Compute'' THEN revenue else 0 end)*12 as COMPUTE_REVENUE
        , SUM(case when revenue_group = ''Storage'' THEN revenue else 0 end)*12 as STORAGE_REVENUE
        , SUM(case when revenue_group = ''Other'' THEN revenue else 0 end)*12 as OTHER_REVENUE
        , SUM(REVENUE)*12 as total_revenue
        , SUM(CREDITS)*12 as total_credits
        , SUM(STORAGE_TB)*12 as total_storage_tb
        FROM {billing_table} b
        JOIN {scoped_table} s
            on s.account_id = b.account_id
            and s.deployment = b.deployment
        WHERE true
        and month = ''{previous_month_start}''
        GROUP BY ALL
        )
        
        SELECT t.*
        , a.total_revenue
        , a.total_credits
        , a.total_storage_tb
        , a.COMPUTE_REVENUE
        , a.STORAGE_REVENUE
        , a.OTHER_REVENUE
        , DIV0((t.low_warehouse_consolidation_dollar_savings + t.low_warehouse_sizing_dollar_savings+ t.low_warehouse_timeout_dollar_savings + t.low_erroring_queries_annualized_dollar_savings + t.low_repeated_queries_annualized_dollar_savings + low_copy_annualized_dollar_savings + t.low_autosuspend_dollar_savings),compute_revenue) as low_compute_percentage_savings
        , DIV0((t.high_warehouse_consolidation_dollar_savings + t.high_warehouse_sizing_dollar_savings+ t.high_warehouse_timeout_dollar_savings + t.high_erroring_queries_annualized_dollar_savings + t.high_repeated_queries_annualized_dollar_savings + high_copy_annualized_dollar_savings + high_autosuspend_dollar_savings),compute_revenue) as high_compute_percentage_savings
        , DIV0((t.low_inactive_storage_annualized_savings_dollars + t.low_unused_storage_annualized_savings_dollars),storage_revenue) as low_storage_percent_savings
        , DIV0((t.high_inactive_storage_annualized_savings_dollars + t.high_unused_storage_annualized_savings_dollars),storage_revenue) as high_storage_percent_savings
        , DIV0((t.low_snowpipe_annualized_dollar_savings + t.low_autocluster_annualized_dollar_savings + t.low_unused_autocluster_annualized_savings_dollars),other_revenue) as low_other_percent_savings
        , DIV0((t.high_snowpipe_annualized_dollar_savings + t.high_autocluster_annualized_dollar_savings  + t.high_unused_autocluster_annualized_savings_dollars),other_revenue) as high_other_percent_savings
        , DIV0(t.total_low_annualized_dollar_savings,a.total_revenue) as total_low_percentage_savings
        , DIV0(t.total_high_annualized_dollar_savings,a.total_revenue) as total_high_percentage_savings
        FROM {total_account_savings} t
        LEFT JOIN ANNUALIZED_COST a
        on a.account_id = t.account_id
        and a.deployment = t.deployment
        order by total_revenue desc 
        )
        ;
        """
        
 # Execute the view queries
        session.sql(SAVINGS_ADJUSTMENTS_CVA).collect()
        session.sql(TOTAL_ACCOUNT_AGG_CVA).collect()
        session.sql(ACCOUNT_ROCKS_AGG_CVA).collect()
        session.sql(SCOPED_ACCOUNTS_ROCKS_SUMMARY_CVA).collect()
        session.sql(SAVINGS_ACCOUNT_CONTEXTUALIZATION_CVA).collect()
        
        
        return ''Views created successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
