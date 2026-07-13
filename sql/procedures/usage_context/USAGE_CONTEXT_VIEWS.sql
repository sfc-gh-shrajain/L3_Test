CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.USAGE_CONTEXT_VIEWS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'usage_context_views'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def usage_context_views(session, cust_name: str):
    try:
        # define variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        UEM_table = f''{schema}.UEM''
        UEQ_table = f''{schema}.UEQ''
        UEW_table = f''{schema}.UEW''
        UEM_COMBINED = f''{schema}.UEM_COMBINED''
        UEQ_COMBINED = f''{schema}.UEQ_COMBINED''
        UEW_COMBINED = f''{schema}.UEW_COMBINED''
        billing_table = f''{schema}.BILLING''

        # Current quarter start date
        current_quarter_start_date = session.sql("SELECT date_trunc(''quarter'', current_date())").collect()[0][0]
        current_quarter_start_date = current_quarter_start_date.strftime(''%Y-%m-%d'')

        # End of Previous Month
        previous_month_end = session.sql("SELECT DATEADD(''day'',-1,DATE_TRUNC(''month'',CURRENT_DATE()))").collect()[0][0]
        previous_month_end = previous_month_end.strftime(''%Y-%m-%d'')

        # Two year prior beginning date
        prior_two_year_beginning_date = session.sql(f"SELECT dateadd(year, -2, dateadd(month, -3, ''{current_quarter_start_date}''::DATE))").collect()[0][0]
        prior_two_year_beginning_date = prior_two_year_beginning_date.strftime(''%Y-%m-%d'')

    # Create Monthly Unit Economics analysis query View
        UEM_COMBINED_CVA = f"""
        CREATE OR REPLACE VIEW {UEM_COMBINED} AS (
            WITH MONTHLY_BILLING AS (
            SELECT 
            MONTH
           // ,b.sf_id
           // ,b.sf_name
            ,s.ACCOUNT_ID
            ,b.NAME
            ,b.ALIAS
            ,s.DEPLOYMENT
            ,period
            ,MIN(month) as month_date
            ,SUM(revenue) as revenue
            ,SUM(CREDITS) as credits
            ,SUM(CASE WHEN revenue_category IN (''Compute'',''Reader Compute'') THEN CREDITS ELSE 0 END) as COMPUTE_CREDITS
            ,SUM(CASE WHEN revenue_category NOT IN (''Compute'',''Reader Compute'') THEN CREDITS ELSE 0 END) as SERVERLESS_CREDITS
            ,SUM(STORAGE_TB) as storage_tb
            ,SUM(transfer_tb) as transfer_tb
            FROM {billing_table} b
            JOIN {scoped_table} s
                    on s.account_id = b.account_id
                    and s.deployment = b.deployment
            GROUP BY ALL
            )
            
            SELECT 
            //sf_name
            //,alias
            u.account_id
            ,u.deployment
            ,q.alias
            ,q.period
            ,q.month_date
            ,SUM(credits) as total_credits
            ,SUM(xp_jobs) as total_jobs
            ,SUM(bytes_scanned)/pow(1024,4) as total_tb_scanned
            ,SUM(u.dur_xp_executing)/1000/3600 as total_execution_hours
            ,SUM(COMPUTE_CREDITS) as total_compute_credits
            ,SUM(SERVERLESS_CREDITS) as total_serverless_credits
            ,SUM(ACTIVE_USERS) as total_active_users
            ,SUM(USED_DATABASE) as total_used_databases
            ,SUM(USED_SCHEMA) as total_used_schemas
            ,SUM(USED_WAREHOUSE) as total_used_warehouses
            ,DIV0(total_credits,(total_jobs/1000)) as credits_per_thousand_queries
            ,DIV0(total_credits,total_tb_scanned) as credits_per_tb_scanned
            FROM {UEM_table} u
            LEFT JOIN MONTHLY_BILLING q
                on u.account_id = q.account_id
                and u.month = q.month
                and u.deployment = q.deployment
            WHERE true
            GROUP BY ALL
            )
            ;
        """
    # Create Quarterly Unit Economics analysis query View
        UEQ_COMBINED_CVA = f"""
        //Quarterly Billing
            CREATE OR REPLACE VIEW {UEQ_COMBINED} AS (
            WITH QUARTERLY_BILLING AS (
            SELECT 
            PERIOD
            //,b.sf_id
            //,b.sf_name
            ,s.ACCOUNT_ID
            ,b.NAME
            ,b.ALIAS
            ,s.DEPLOYMENT
            ,MIN(month) as quarter_date
            ,SUM(revenue) as revenue
            ,SUM(CREDITS) as credits
            ,SUM(CASE WHEN revenue_category IN (''Compute'',''Reader Compute'') THEN CREDITS ELSE 0 END) as COMPUTE_CREDITS
            ,SUM(CASE WHEN revenue_category NOT IN (''Compute'',''Reader Compute'') THEN CREDITS ELSE 0 END) as SERVERLESS_CREDITS
            ,SUM(STORAGE_TB) as storage_tb
            ,SUM(transfer_tb) as transfer_tb
            FROM {billing_table} b
            JOIN {scoped_table} s
                    on s.account_id = b.account_id
                    and s.deployment = b.deployment
            GROUP BY ALL
            )
            
            SELECT 
            //sf_name
            //,alias
            u.account_id
            ,u.deployment
            ,q.alias
            ,q.period
            ,q.quarter_date
            ,SUM(credits) as total_credits
            ,SUM(xp_jobs) as total_jobs
            ,SUM(bytes_scanned)/pow(1024,4) as total_tb_scanned
            ,SUM(u.dur_xp_executing)/1000/3600 as total_execution_hours
            ,SUM(COMPUTE_CREDITS) as total_compute_credits
            ,SUM(SERVERLESS_CREDITS) as total_serverless_credits
            ,SUM(ACTIVE_USERS) as total_active_users
            ,SUM(USED_DATABASE) as total_used_databases
            ,SUM(USED_SCHEMA) as total_used_schemas
            ,SUM(USED_WAREHOUSE) as total_used_warehouses
            ,DIV0(total_credits,(total_jobs/1000)) as credits_per_thousand_queries
            ,DIV0(total_credits,total_tb_scanned) as credits_per_tb_scanned
            FROM {UEQ_table} u 
            LEFT JOIN QUARTERLY_BILLING q
                on u.account_id = q.account_id
                and u.period = q.period
                and u.deployment = q.deployment
            WHERE true
            GROUP BY ALL
            )
            ;
        """

    # Create Warehouse Unit Economics query View
        UEW_COMBINED_CVA = f"""
        CREATE OR REPLACE VIEW {UEW_COMBINED} AS (
        WITH MONTHLY_WAREHOUSE_BILLING AS (
                select
                    YEAR(USAGE_DATE::DATE) || ''-Q''  || QUARTER(USAGE_DATE::DATE) AS PERIOD
                    ,DATE_TRUNC(''month'', USAGE_DATE::DATE) as MONTH
                    ,m.SNOWFLAKE_ACCOUNT_ID  as ACCOUNT_ID
                    ,m.SNOWFLAKE_DEPLOYMENT as DEPLOYMENT
                    //,WAREHOUSE_ID
                    ,WAREHOUSE_NAME
                    ,ROUND(SUM(CREDITS),2) as CREDITS_XP
                from FINANCE.CUSTOMER.WAREHOUSE_COMPUTE m
                JOIN 
                -- FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS S
                {scoped_table} S 
                        on m.snowflake_account_id = S.ACCOUNT_ID
                        and m.snowflake_deployment = S.deployment
            WHERE true
            -- AND m.USAGE_DATE::DATE between ''2023-11-01'' AND ''2024-12-31''
            AND m.USAGE_DATE::DATE between ''{prior_two_year_beginning_date}'' AND ''{previous_month_end}''
            AND m.WAREHOUSE_ID NOT IN (0,-2)
            AND m.CREDITS > 0
            GROUP BY ALL )
    
            SELECT
            u.account_id
            ,u.deployment
            ,A.account_name as alias
            ,m.period
            ,m.month
            ,m.warehouse_name
            ,SUM(CREDITS_XP) as total_credits
            ,SUM(xp_jobs) as total_jobs
            ,SUM(bytes_scanned)/pow(1024,4) as total_tb_scanned
            ,SUM(u.dur_xp_executing)/1000/3600 as total_execution_hours
            ,SUM(ACTIVE_USERS) as total_active_users
            ,SUM(USED_DATABASE) as total_used_databases
            ,SUM(USED_SCHEMA) as total_used_schemas
            ,DIV0(total_credits,(total_jobs/1000)) as credits_per_thousand_queries
            ,DIV0(total_credits,total_tb_scanned) as credits_per_tb_scanned
            FROM 
            -- FINOPS.SIEMENS_AG.UEW u
            {UEW_table} u 
            LEFT JOIN MONTHLY_WAREHOUSE_BILLING m
                on u.account_id = m.account_id
                and u.month = m.month
                and u.deployment = m.deployment
                and u.warehouse_name = m.warehouse_name
            LEFT JOIN 
            -- FINOPS.SIEMENS_AG.SCOPED_ACCOUNTS A
            {scoped_table} A
                on A.account_id = u.account_id
                and A.deployment = u.deployment
            WHERE true
            GROUP BY ALL
            )
            ;
        """
  
 # Execute the view queries
        session.sql(UEM_COMBINED_CVA).collect()
        session.sql(UEQ_COMBINED_CVA).collect()
        session.sql(UEW_COMBINED_CVA).collect()
        
        return ''Views created successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
