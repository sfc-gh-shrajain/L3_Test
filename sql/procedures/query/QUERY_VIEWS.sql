CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.QUERY_VIEWS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'query_analysis'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def query_analysis(session, cust_name: str):
    try:
        # define variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        cost_table = f''{schema}.COST_TABLE''
        query_agg = f''{schema}.QUERY_ACCOUNT_AGG''
        repeated_queries = f''{schema}.REPEATED_QUERIES''
        copy_analysis_table = f''{schema}.COPY_ANALYSIS_TABLE''
        copy_history_table = f''{schema}.COPY_HISTORY_TABLE''
        copy_analysis = f''{schema}.COPY_ANALYSIS''
        
        # Days in Month
        days_in_previous_month = session.sql("SELECT DAY(DATEADD(''day'',-1, DATE_TRUNC(''month'',CURRENT_DATE())))").collect()[0][0]

    # Create copy analysis query View
        QUERY_COPY_TABLE_CVA = f"""
        CREATE OR REPLACE VIEW {copy_analysis_table} AS (
            //need to validate the amount in savings for adjusting file sizes. Currently set at a conservative 25%
            SELECT
            c.account_id
            ,c.deployment
            ,c.table_name
            ,c.ingest_type
            ,c.total_files 
            ,c.total_queries
            ,c.avg_file_size_mb
            ,c.max_file_size_mb
            ,c.min_file_size_mb
            ,stddev_file_size_mb
            ,c.total_file_size_mb
            ,abs(avg_file_size_mb-c.stddev_file_size_mb)/avg_file_size_mb as std_diff_from_mean
            ,c.file_over_250mb
            ,c.file_under_100mb
            ,c.file_under_10mb
            ,c.p50_filze_size
            ,c.p80_filze_size
            ,c.p95_filze_size
            ,c.conservative_wh_sizing_diff
            ,avg_wh_server_size
            ,SUM(CASE WHEN 
            (file_over_250mb + file_under_100mb)/total_files >= .95
            THEN total_credits 
            WHEN conservative_wh_sizing_diff <= -1 THEN total_credits
            ELSE 0 END) as low_credits
            ,SUM(CASE WHEN 
            (file_over_250mb + file_under_100mb)/total_files >= .8
            THEN total_credits
            WHEN conservative_wh_sizing_diff <= -1 THEN total_credits
            ELSE 0 END) as high_credits
            ,SUM(total_credits) as total_table_loading_credits
            ,total_table_loading_credits/(total_file_size_mb/1024/1024) as credits_per_tb_loaded
            ,case 
            WHEN conservative_wh_sizing_diff <= -1 THEN 1 - (1/pow(2,abs(conservative_wh_sizing_diff)))
            when std_diff_from_mean > .34 AND NOT(p95_filze_size BETWEEN 100 and 250) AND credits_per_tb_loaded > 25 THEN .5
                WHEN std_diff_from_mean > .34 AND NOT(p80_filze_size BETWEEN 100 and 250) AND credits_per_tb_loaded > 25 THEN .4
                WHEN std_diff_from_mean > .34 and credits_per_tb_loaded > 25 THEN .3
                ELSE .25
                END as potential_savings
            ,low_credits*potential_savings as low_credits_potential_savings
            ,high_credits*potential_savings as high_credits_potential_savings
            FROM {copy_history_table} c
            WHERE 
                total_file_size_mb > 1024 //at least 1 GB loaded across the last month
                and total_files > (30) //at least 1 file a day 
            GROUP BY ALL
            )
            ;
        """
    # Create copy analysis query View
        QUERY_COPY_CVA = f"""
        CREATE OR REPLACE VIEW {copy_analysis} AS (
            //need to validate the amount in savings for adjusting file sizes. Currently set at a conservative 25%
            SELECT
            c.account_id
            ,c.deployment
            ,c.ingest_type
            ,COUNT(c.table_name) as table_num
            ,SUM(c.total_files) as account_total_files
            ,SUM(c.total_file_size_mb) as account_total_file_size_mb
            ,account_total_file_size_mb/account_total_files as account_avg_file_size
            ,SUM(total_table_loading_credits)/(account_total_file_size_mb/1024/1024) as account_credits_per_tb_scanned
            ,SUM(low_credits_potential_savings) as low_credit_savings_potential
            ,SUM(high_credits_potential_savings) as high_credit_savings_potential
            FROM {copy_analysis_table} c
            GROUP BY ALL
            )
            ;
        """
        
    # Create Query Aggregate View
        QUERY_AGG_CVA = f"""
        CREATE OR REPLACE VIEW {query_agg} AS (
        SELECT 
        a.account_id
        ,a.deployment
        ,a.locator
        ,a.account_name
        ,IFNULL(SUM(case when error_rate_no_cancelation_by_credits > (500/12) and errored >= 4 THEN error_rate_no_cancelation_by_credits*(365/{days_in_previous_month}) ELSE 0 END),0) as error_credits_repeated
        ,error_credits_repeated * AVG(c.price_per_credit) as error_savings_dollars
        ,SUM(CASE WHEN numqueries >= 4 THEN annualized_nonerror_job_credits*(30/{days_in_previous_month}) ELSE 0 END) as repeated_queries_credits
        ,repeated_queries_credits * AVG(c.price_per_credit) as repeated_queries_savings_dollars
        ,MAX(ca.low_credit_savings_potential)*(365/{days_in_previous_month}) as low_copy_credit_savings
        ,MAX(ca.high_credit_savings_potential)*(365/{days_in_previous_month}) as high_copy_credit_savings
        ,low_copy_credit_savings * AVG(c.price_per_credit) as low_copy_dollar_savings
        ,high_copy_credit_savings * AVG(c.price_per_credit) as high_copy_dollar_savings
        FROM {scoped_table} a
        LEFT JOIN  {repeated_queries} r
            on a.account_id = r.account_id
            and a.deployment = r.deployment
        LEFT JOIN {cost_table} c
            on c.account_id = a.account_id
            and c.deployment = a.deployment
        LEFT JOIN {copy_analysis} ca
            on ca.account_id = a.account_id
            and ca.deployment = a.deployment
        WHERE true
        GROUP BY ALL
        )
        ;
        """
        
        

 # Execute the view queries
        session.sql(QUERY_COPY_TABLE_CVA).collect()
        session.sql(QUERY_COPY_CVA).collect()
        session.sql(QUERY_AGG_CVA).collect()
        
        return ''Views created successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
