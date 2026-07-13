CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.REPEATED_QUERIES("CUST_NAME" VARCHAR)
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

        # Start of Previous Month
        previous_month_start = session.sql("SELECT DATEADD(''month'',-1, DATE_TRUNC(''month'',CURRENT_DATE()))").collect()[0][0]
        previous_month_start = previous_month_start.strftime(''%Y-%m-%d'')

        # End of Previous Month
        previous_month_end = session.sql("SELECT DATEADD(''day'',-1,DATE_TRUNC(''month'',CURRENT_DATE()))").collect()[0][0]
        previous_month_end = previous_month_end.strftime(''%Y-%m-%d'')

        # Set deployment variables
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        repeat_table = f''{schema}.REPEATED_QUERIES''
        query_history = f''{schema}.QUERY_HISTORY_30D''

        # Insert data into identifier table
        INSERT_QUERY = f"""
INSERT INTO {repeat_table} (
WITH JOB_CREDITS_TABLE AS (
SELECT 
J.account_id
,J.deployment
,job_uuid
,credits
FROM SNOWSCIENCE.JOB_ANALYTICS.JOB_CREDITS J
join {scoped_table} S
    on j.account_id = S.account_id
    and j.deployment = S.deployment
WHERE true
and original_start_at BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}''
)
,TOP_QUERIES AS (
SELECT 
qh.account_id
,qh.deployment
,query_parameterized_hash
//,COUNT(DISTINCT query_parameterized_hash) as Parameterized_Query_Hash
,SUM(EXECUTING_SEC * WAREHOUSE_SERVER_SIZE)/3600 as WEIGHTED_XP
,AVG(EXECUTING_SEC) as AVG_EXEC
,SUM(CASE WHEN REUSED_JOB_ID IS NOT NULL THEN 1 ELSE 0 END) as QUERY_FROM_CACHE
,COUNT(*) as NumQueries
,DIV0(WEIGHTED_XP,NumQueries) as WEIGHTED_XP_PER_QUERY
,SUM(CASE WHEN ERROR_CODE IS NOT NULL AND ERROR_CODE != ''000604'' THEN 1 ELSE 0 END) as ERRORED
,SUM(CASE WHEN ERROR_CODE IS NOT NULL AND ERROR_CODE != ''000604'' THEN credits ELSE 0 END) as ERROR_CREDITS
,SUM(CASE WHEN ERROR_CODE IS NOT NULL AND ERROR_CODE = ''000604'' THEN 1 ELSE 0 END) as CANCELLED
,SUM(CASE WHEN ERROR_CODE IS NOT NULL AND ERROR_CODE = ''000604'' THEN credits ELSE 0 END) as CANCELLED_CREDITS
,MAX(DESCRIPTION) as example_query
,MAX(TRIMMED_QUERY) as example_hash_query
,MAX(ERROR_MESSAGE) as example_error_messages
,MAX(WAREHOUSE_NAME) as example_warehouse_name
,COUNT(DISTINCT WAREHOUSE_NAME) as num_whs_run_in
,AVG(WAREHOUSE_SERVER_SIZE) as avg_wh_server_size
,SUM(GB_SPILLED_TO_REMOTE_STORAGE) as GB_SPILLED
,SUM(bytes_scanned/1024/1024/1024/1024) as TB_SCANNED
,COUNT(jc.job_uuid) as num_job_credits
,SUM(CASE WHEN jc.credits > 0 THEN 1 ELSE 0 END) as job_credit_query_with_exec
,SUM(CASE WHEN EXECUTING_SEC > 0 THEN 1 ELSE 0 END) as queries_with_exec
,SUM(jc.credits) as job_credits
FROM {query_history} qh
LEFT JOIN JOB_CREDITS_TABLE jc 
    on jc.job_uuid = qh.query_id
    and qh.account_id = jc.account_id
    and qh.deployment = jc.deployment
GROUP BY ALL
) 
, ACCOUNT_TOTALS AS 
(
SELECT 
account_id
,deployment
,SUM(WEIGHTED_XP) as ACCOUNT_WEIGHTED_XP
,SUM(ERROR_CREDITS-CANCELLED_CREDITS) as ACCOUNT_ERROR_CREDITS
//,SUM(WEIGHTED_XP) OVER (ORDER BY NULL) as TOTAL_WEIGHTED_XP
,SUM(job_credits) as account_job_credits
FROM TOP_QUERIES
GROUP BY ALL
)
,ALL_UP_TOTAL AS (
SELECT 
SUM(ACCOUNT_WEIGHTED_XP) as ALL_WEIGHTED_XP
,SUM(account_job_credits) as all_job_credits
,SUM(ACCOUNT_ERROR_CREDITS) as all_error_credits
FROM ACCOUNT_TOTALS
)

SELECT 
q.account_id
,q.deployment
,q.query_parameterized_hash
//,COUNT(DISTINCT query_parameterized_hash) as Parameterized_Query_Hash
,q.WEIGHTED_XP
,q.AVG_EXEC
,q.QUERY_FROM_CACHE
,q.NumQueries
,q.WEIGHTED_XP_PER_QUERY
,q.ERRORED
,q.example_error_messages
,LEFT(q.example_query,500) as example_query_shortened
//left(q.example_Hash_query,100) as example_hash_query_shortened
,q.example_warehouse_name
,q.num_whs_run_in
,q.avg_wh_server_size
,q.GB_SPILLED
,q.TB_SCANNED
,q.num_job_credits
,job_credit_query_with_exec
,queries_with_exec
,q.job_credits
,t.ACCOUNT_WEIGHTED_XP
,at.ALL_WEIGHTED_XP
,t.account_job_credits
,at.all_job_credits
,cancelled
,cancelled_credits
,(CANCELLED_CREDITS/job_credits)*100 as cancelled_credits_perc_of_total
,error_credits-cancelled_credits as error_credits_no_cancellations
,(WEIGHTED_XP/ACCOUNT_WEIGHTED_XP)*100 as WEIGHTED_XP_ACCOUNT_PERC_OF_TOTAL
,(WEIGHTED_XP/ALL_WEIGHTED_XP)*100 as WEIGHTED_XP_PERC_OF_TOTAL
,(job_credits/account_job_credits)*100 as account_job_credits_perc_of_total
,(job_credits/all_job_credits)*100 as job_credits_perc_of_total
,job_credits*(365/30) as annualized_job_credits
,annualized_job_credits*.2 as annualized_savings_20p
,annualized_job_credits*.3 as annualized_savings_30p
,SUM(job_credits_perc_of_total) OVER (ORDER BY job_credits_perc_of_total DESC) as running_total_job_credit
,q.ERROR_CREDITS
,(error_credits_no_cancellations/all_error_credits)*100 as error_credits_perc_of_total
,SUM(error_credits_perc_of_total) OVER (ORDER BY error_credits_perc_of_total DESC) as running_total_error_credit
,DIV0(errored,NumQueries)*100 as ERROR_RATE
,DIV0(error_credits_no_cancellations,job_credits)*100 as error_rate_no_cancelation_by_credits
,error_credits_no_cancellations*(365/30) as annualized_error_cost
,annualized_error_cost*.2 as annualized_error_savings_20p
,annualized_error_cost*.3 as annualized_error_savings_30p
,DIV0(QUERY_FROM_CACHE,NumQueries)*100 as result_cached_query_percentage
,DIV0(job_credits,job_credit_query_with_exec)*QUERY_FROM_CACHE as potential_savings_from_results_cache
,potential_savings_from_results_cache*.3*(365/30) as potential_annualized_savings_from_results_cache_30p
,potential_savings_from_results_cache*.5 *(365/30) as potential_annualized_savings_from_results_cache_50p
,(job_credits-error_credits)*(365/30) as annualized_nonerror_job_credits
,annualized_nonerror_job_credits*.2 as annualized_nonerror_savings_20p
,annualized_nonerror_job_credits*.3 as annualized_nonerror_savings_30p
,ROW_NUMBER() OVER (ORDER BY job_credits_perc_of_total DESC NULLS LAST ) as job_credit_rank
,ROW_NUMBER() OVER (ORDER BY annualized_error_cost DESC NULLS LAST ) as error_credit_rank
,ROW_NUMBER() OVER (ORDER BY potential_savings_from_results_cache DESC NULLS LAST ) as results_cache_rank
,ROW_NUMBER() OVER (ORDER BY annualized_nonerror_job_credits DESC NULLS LAST ) as nonerror_job_credit_rank
FROM TOP_QUERIES q
JOIN ACCOUNT_TOTALS t
    on q.account_id = t.account_id
    and q.deployment = t.deployment
CROSS JOIN ALL_UP_TOTAL at
WHERE job_credits_perc_of_total IS NOT NULL
QUALIFY (running_total_job_credit <= 20  OR annualized_error_cost >= 500)
//AND annualized_savings_30p > 1000
ORDER BY job_credits_perc_of_total DESC
);
        """

        # Execute the insert query
        session.sql(INSERT_QUERY).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
