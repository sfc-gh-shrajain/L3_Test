CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.ROI_VIEWS("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'other_analysis'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging
import time
import pandas as pd

logger = logging.getLogger("python_logger")

def other_analysis(session, cust_name: str):
    try:
        # define variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        cost_table = f''{schema}.COST_TABLE''
        result_cache_savings = f''{schema}.RESULT_CACHE_SAVINGS''
        query_history = f''{schema}.QUERY_HISTORY_30D''
        query_attribution_30D = f''{schema}.ATTRIBUTED_COST_QUERY_HISTORY_30D''
        data_sharing = f''{schema}.DATA_SHARING_ROI''
        
    # Create results cache query View
        RESULT_CACHE_SAVINGS_CVA = f"""
        CREATE OR REPLACE VIEW {result_cache_savings} AS (
          WITH QUERIES AS (
            SELECT 
            qh.account_id
            ,qh.deployment
            //,rji.query_only as original_query
            //,qh.query_only
            ,rji.query_id
            ,COUNT(*) as num_queries
            FROM {query_history} qh
            JOIN {query_history} rji on rji.job_id = qh.reused_job_id and qh.account_id = rji.account_id and qh.deployment = rji.deployment
            WHERE true
            and qh.REUSED_JOB_ID IS NOT NULL
            and qh.query_only not ilike ''%table(%result_scan(%'' //removes cases where stored procedures call results
            //and rji.query_parameterized_hash = ''a684f8f89ece5353310d419e53a67405''
            GROUP BY ALL
            )
            ,TOTAL_ATTRIBUTED_CREDITS AS (
            SELECT 
            account_id
            ,deployment
            ,SUM(CREDITS_ATTRIBUTED_COMPUTE) as monthly_attributed_compute
            FROM 
            -- FINOPS.MICRON_250203.ATTRIBUTED_COST_QUERY_HISTORY_30D qac
            {query_attribution_30D} qac
            GROUP BY ALL
            )
            
            SELECT qac.ACCOUNT_ID
            ,account_name
            ,qac.DEPLOYMENT
            //,qac.query_parameterized_hash
            //,qac.query_id
            ,COUNT(DISTINCT query_parameterized_hash) as distinct_param_hashes
            //,COUNT(DISTINCT query_hash) as distinct_conservative_hashes
            //,ANY_VALUE(qac.query_id) as example_query_id
            //,ANY_VALUE(q.original_query) as example_original_query
            //,ANY_VALUE(q.query_only) as example_repeated_query
            ,ROUND(SUM(CREDITS_ATTRIBUTED_COMPUTE*num_queries),0) as credits_attributed_to_result_cache
            ,SUM(num_queries) as num_queries
            ,SUM(CREDITS_ATTRIBUTED_COMPUTE) as credits_attributed_total
            ,AVG(c.price_per_credit)*credits_attributed_to_result_cache as monthly_dollar_savings_from_result_cache
            ,MAX(tac.monthly_attributed_compute) as account_monthly_attributed_compute
            ,DIV0(credits_attributed_to_result_cache,account_monthly_attributed_compute)*100 as ROI_PERCENT_OF_MONTHLY_COMPUTE
            FROM {query_attribution_30D} qac
            JOIN QUERIES q 
                on q.account_id = qac.account_id
                and q.deployment = qac.deployment
                and q.query_id = qac.query_id
            JOIN {scoped_table} s
                on s.account_id = qac.account_id 
                and s.deployment = qac.deployment
            JOIN {cost_table} c
                on c.account_id = qac.account_id 
                and c.deployment = qac.deployment
            JOIN TOTAL_ATTRIBUTED_CREDITS tac
                on tac.account_id = qac.account_id
                and tac.deployment = qac.deployment
            GROUP BY ALL
            HAVING credits_attributed_total IS NOT NULL
            ORDER BY credits_attributed_total DESC
            )
            ;
        """

 # Execute the view queries
        session.sql(RESULT_CACHE_SAVINGS_CVA).collect()
        
        return ''Views created successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
