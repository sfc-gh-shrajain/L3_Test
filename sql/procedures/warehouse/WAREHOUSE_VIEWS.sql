CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.WAREHOUSE_VIEWS("CUST_NAME" VARCHAR)
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
        cost_table = f''{schema}.COST_TABLE''
        warehouse_config = f''{schema}.WAREHOUSE_CONFIGURATION''
        auto_suspend = f''{schema}.AUTO_SUSPEND''
        timeout_policy = f''{schema}.TIMEOUT_POLICIES''
        warehouse_load = f''{schema}.WAREHOUSE_LOAD_HISTORY''
        warehouse_score = f''{schema}.WAREHOUSE_SCORING''
        warehouse_credits = f''{schema}.WAREHOUSE_CREDITS''
        warehouse_utilization = f''{schema}.WAREHOUSE_UTILIZATION''
        warehouse_query_timeout = f''{schema}.QUERY_TIMEOUT_WASTE''
        query_attribution_history = f''{schema}.ATTRIBUTED_COST_QUERY_HISTORY_30D''
        warehouse_agg = f''{schema}.WAREHOUSE_AGG''
        warehouse_account = f''{schema}.WAREHOUSE_ACCOUNT_AGG''
        warehouse_idle_time = f''{schema}.WAREHOUSE_IDLE_TIME''

        # Create Auto_Suspend VIEW logic
        AUTO_SUSPEND_CVA = f"""
        CREATE OR REPLACE VIEW {auto_suspend} AS (   
        SELECT 
        salesforce_account_id,
        salesforce_account_name,
        account_id,
        deployment,
        auto_suspend,
        COUNT(warehouse_id) as NB_WH,
        round(100 * RATIO_TO_REPORT(COUNT(warehouse_id)) OVER (PARTITION BY account_id, deployment),2) AS percent_NB_WH  
        FROM {warehouse_config}
        GROUP BY ALL
        );        
        """
        
        # Create Timeout_Policies VIEW logic
        TIMEOUT_POLICIES_CVA = f"""
        CREATE OR REPLACE VIEW {timeout_policy} AS (   
        SELECT 
            salesforce_account_id
            ,salesforce_account_name
            ,account_id
            ,deployment
            ,ROUND(TIMEOUT_HOURS,0) as TIMEOUT_HOURS
            ,COUNT(warehouse_id) as NB_ID
        FROM {warehouse_config}
        GROUP BY ALL
        );
            """

        # Create Warehouse Level Aggregate View
        WAREHOUSE_AGG_CVA = f"""
        CREATE OR REPLACE VIEW {warehouse_agg} AS (
        WITH WAREHOUSE_IDLE_TIME AS (
        SELECT 
            account_id
            ,deployment
            ,warehouse_name
            ,sum(credits_attributed_compute) as attributed_compute_credits
            ,SUM(CASE WHEN executing_sec > 0 AND executing_sec < .25 AND IFNULL(CREDITS_ATTRIBUTED_COMPUTE,0) = 0 THEN 1 ELSE 0 END) as short_queries
            ,SUM(CASE WHEN executing_sec > 0 AND executing_sec < .25 AND IFNULL(CREDITS_ATTRIBUTED_COMPUTE,0) = 0 THEN executing_sec ELSE 0 END) as short_query_durations
            ,SUM(executing_sec) as total_seconds
            ,SUM(CASE WHEN executing_sec > 0 THEN 1 ELSE 0 END) as num_queries
            ,DIV0(short_queries,num_queries) * 100 as perc_short_queries
            ,DIV0(short_query_durations,total_seconds)*100 as perc_short_query_duration
            ,SUM(BYTES_SCANNED)/pow(1024,4) as TB_SCANNED
        FROM {query_attribution_history}
        GROUP BY ALL
        )
        
        SELECT 
            wc.account_id
            ,s.locator
            ,s.account_name
            ,wc.deployment
            ,wc.month
            ,wc.warehouse_id
            ,wc.warehouse_name
            ,wlh.avg_running as avg_query_concurrency
            ,wlh.p80 as p80_query_concurrency
            ,wlh.p95 as p95_query_concurrency
            ,wlh.avg_queued_load as avg_query_concurrency_queued_load
            ,ws.sizing_details
            ,ws.WEIGHTED_AVG_WH_LOAD as avg_wh_load
            ,ws.WEIGHTED_P80_WH_LOAD as p80_wh_load
            ,ws.WEIGHTED_P95_WH_LOAD as p95_wh_load
            ,ws.execution_hours
            ,ws.billable_hours
            ,DIV0(ws.execution_hours,ws.billable_hours)*100 as warehouse_efficiency
            ,wu.avg as avg_utilization
            ,wu.p80 as p80_utilization
            ,wu.p95 as p95_utilization
            ,wcon.auto_resume
            ,wcon.auto_suspend
            ,wcon.instance_type
            ,wcon.warehouse_type
            ,wcon.mcw_scaling_type
            ,wcon.min_cluster_count
            ,wcon.max_cluster_count
            ,wcon.max_concurrency_level
            ,wcon.timeout_hours
            ,wcon.query_acceleration_enabled
            ,wcon.query_acceleration_max_scale_factor
            ,wcon.etl as etl_flag
            ,wcon.comment
            ,wcon.current_size as current_size_at_analysis_runtime
            ,wc.credits_xp
            ,wit.attributed_compute_credits
            ,wc.credits_xp - wit.attributed_compute_credits as idle_credits
            ,DIV0(idle_credits,credits_xp) * 100 as idle_percentage
            ,wit.perc_short_queries
            ,wit.perc_short_query_duration 
            ,was.idle_cluster_minutes_after_60s
            ,was.total_active_cluster_minutes
            ,was.total_idle_cluster_minutes
            ,(idle_cluster_minutes_after_60s/total_active_cluster_minutes) * 100 as perc_idle_after_60s
            ,CASE WHEN auto_suspend <= 60 THEN 0 
                  WHEN warehouse_type = ''INTERACTIVE'' THEN 0
            ELSE IFNULL((perc_idle_after_60s/100)*credits_xp,0) END as idle_credits_from_autosuspend
            -- ,wit.num_queries as xp_jobs //value seems way over inflated, multiple times larger than UEW in many cases.
            -- ,wit.TB_SCANNED as tb_scanned //value appears correct.
            ,IFNULL(qtw.lowerboundcreditssaved_percentage,0) as low_query_timeout_savings_percentage
            ,IFNULL(qtw.upperboundcreditssaved_percentage,0) as high_query_timeout_savings_percentage
 //           ,IFNULL(ws.estimated_low_credit_savings,0) as low_sizing_credit_savings
 //           ,IFNULL(ws.estimated_high_credit_savings,0) as high_sizing_credit_savings
            ,IFNULL((ws.estimated_low_credit_savings/credits_xp)*(credits_xp-idle_credits_from_autosuspend),0) as low_sizing_credit_savings //adjusting for idle_credits_from_autosuspend
            ,IFNULL((ws.estimated_high_credit_savings/credits_xp)*(credits_xp-idle_credits_from_autosuspend),0) as high_sizing_credit_savings //adjusting for idle_credits_from_autosuspend
            ,IFNULL(
                case when warehouse_type = ''INTERACTIVE'' THEN 0
                when wlh.p95 < 1 THEN (wc.credits_xp-idle_credits_from_autosuspend)*.25 
                ELSE 0 END,0) AS low_concurrency_credit_savings
            ,IFNULL(
                case when warehouse_type = ''INTERACTIVE'' THEN 0 
                when wlh.p80 < 1 THEN (wc.credits_xp-idle_credits_from_autosuspend)*.25 
                ELSE 0 END,0) AS high_concurrency_credit_savings
            ,(IFNULL(lowerboundcreditssaved_percentage,0)/100) * (credits_xp - idle_credits_from_autosuspend) as low_timeout_credit_savings //adjusting for autosuspend
            ,(IFNULL(upperboundcreditssaved_percentage,0)/100) * (credits_xp - idle_credits_from_autosuspend) as high_timeout_credit_savings //adjusting for autosuspend
            ,CASE WHEN (100-idle_percentage)+perc_short_query_duration <= 40 THEN (credits_xp*.5)-high_concurrency_credit_savings
            ELSE 0 END
            as low_idle_time_credit_savings
            ,CASE WHEN (100-idle_percentage)+perc_short_query_duration <= 70 THEN (credits_xp*.5)-low_concurrency_credit_savings
            ELSE 0 END
            as high_idle_time_credit_savings
        FROM {warehouse_credits} wc
        LEFT JOIN {warehouse_load} wlh
            on wc.account_id = wlh.account_id
            and wc.deployment = wlh.deployment
            and wc.warehouse_id = wlh.warehouse_id
        LEFT JOIN {warehouse_score} ws
            on wc.account_id = ws.account_id
            and wc.deployment = ws.deployment
            and wc.warehouse_id = ws.warehouse_id
        LEFT JOIN {warehouse_utilization} wu
            on wc.account_id = wu.account_id
            and wc.deployment = wu.deployment
            and wc.warehouse_id = wu.warehouse_id
        LEFT JOIN {warehouse_config} wcon
            on wc.account_id = wcon.account_id
            and wc.deployment = wcon.deployment
            and wc.warehouse_id = wcon.warehouse_id
        LEFT JOIN {warehouse_query_timeout} qtw
            on wc.account_id = qtw.account_id
            and wc.deployment = qtw.deployment
            and wc.warehouse_name = qtw.warehouse_name
        LEFT JOIN WAREHOUSE_IDLE_TIME wit
            on wc.account_id = wit.account_id
            and wc.deployment = wit.deployment
            and wc.warehouse_name = wit.warehouse_name
        LEFT JOIN {scoped_table} s
            on wc.account_id = s.account_id
            and wc.deployment = s.deployment
        LEFT JOIN {warehouse_idle_time} was 
             on wc.account_id = was.account_id
            and wc.deployment = was.deployment
            and wc.warehouse_id = was.warehouse_id
        )
        ;
        """
        
        #Create Warehouse Account Level Aggregation View
        WAREHOUSE_ACCOUNT_AGG_CVA = f"""
        CREATE OR REPLACE VIEW {warehouse_account} AS (
        SELECT
            a.account_id
            ,a.deployment
            ,a.locator
            ,a.account_name
            ,month
            
            //warehouse sizing
            ,SUM(low_sizing_credit_savings)*(365/{days_in_previous_month}) as low_sizing_annualized_credit_savings
            ,low_sizing_annualized_credit_savings*AVG(c.price_per_credit) as low_sizing_annualized_dollar_savings
            ,SUM(high_sizing_credit_savings)*(365/{days_in_previous_month}) as high_sizing_annualized_credit_savings
            ,high_sizing_annualized_credit_savings*AVG(c.price_per_credit) as high_sizing_annualized_dollar_savings
            ,SUM(low_concurrency_credit_savings)*(365/{days_in_previous_month}) as low_concurrency_annualized_credit_savings
            
            //warehouse concurrency
            ,low_concurrency_annualized_credit_savings*AVG(c.price_per_credit) as low_concurrency_annualized_dollar_savings
            ,SUM(high_concurrency_credit_savings)*(365/{days_in_previous_month}) as high_concurrency_annualized_credit_savings
            ,high_concurrency_annualized_credit_savings*AVG(c.price_per_credit) as high_concurrency_annualized_dollar_savings
            
            //warehouse timeout
            ,SUM(low_timeout_credit_savings)*(365/{days_in_previous_month}) as low_timeout_annualized_credit_savings
            ,low_timeout_annualized_credit_savings*AVG(c.price_per_credit) as low_timeout_annualized_dollar_savings
            ,SUM(high_timeout_credit_savings)*(365/{days_in_previous_month}) as high_timeout_annualized_credit_savings
            ,high_timeout_annualized_credit_savings*AVG(c.price_per_credit) as high_timeout_annualized_dollar_savings
            
            //idletime
            ,SUM(low_idle_time_credit_savings)*(365/{days_in_previous_month}) as low_idle_time_annualized_credit_savings
            ,low_idle_time_annualized_credit_savings*AVG(c.price_per_credit) as low_idle_time_annualized_dollar_savings
            ,SUM(high_idle_time_credit_savings)*(365/{days_in_previous_month}) as high_idle_time_annualized_credit_savings
            ,high_idle_time_annualized_credit_savings*AVG(c.price_per_credit) as high_idle_time_annualized_dollar_savings
            
            //autosuspend
            ,SUM(idle_credits_from_autosuspend)*(365/{days_in_previous_month}) as low_autosuspend_annualized_credit_savings
            ,low_autosuspend_annualized_credit_savings*AVG(c.price_per_credit) as low_autosuspend_annualized_dollar_savings
            ,SUM(idle_credits_from_autosuspend)*(365/{days_in_previous_month}) as high_autosuspend_annualized_credit_savings
            ,high_autosuspend_annualized_credit_savings*AVG(c.price_per_credit) as high_autosuspend_annualized_dollar_savings
  //          ,''{days_in_previous_month}'' as days_in_month
        FROM {scoped_table} a
        LEFT JOIN {warehouse_agg} w
            on a.account_id = w.account_id
            and a.deployment = w.deployment
        LEFT JOIN {cost_table} c
            on a.account_id = c.account_id
            and a.deployment = c.deployment
        GROUP BY ALL
        )
        ;
        """

            
        # Execute the insert query
        session.sql(AUTO_SUSPEND_CVA).collect()
        session.sql(TIMEOUT_POLICIES_CVA).collect()
        session.sql(WAREHOUSE_AGG_CVA).collect()
        session.sql(WAREHOUSE_ACCOUNT_AGG_CVA).collect()
        
        return ''Views created successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
