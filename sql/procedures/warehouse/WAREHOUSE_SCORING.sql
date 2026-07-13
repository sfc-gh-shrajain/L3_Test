CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.WAREHOUSE_SCORING("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_ws'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_ws(session,cust_name: str):
    try:
        # Define and set variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''

        # Set deployment variables
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        ws_table = f''{schema}.WAREHOUSE_SCORING'';
        credits_table = f''{schema}.WAREHOUSE_CREDITS'';
        wss_table = f''{schema}.WAREHOUSE_SCORING_STAGING'';

        # Insert data into identifier table
        INSERT_QUERY = f"""
INSERT INTO {ws_table} (
//CREATE OR REPLACE TABLE {ws_table} AS (
WITH BASELINE AS (
SELECT 
    f.account_id
    ,f.account_name
    ,f.deployment
    ,f.warehouse_name
    ,f.warehouse_id
    ,f.warehouse_size
    ,f.size_number
    ,credits_per_hour
    ,warehouse_type
    ,resource_constraint
    ,f.warehouse_size_score
    ,f.xp_duration
    ,f.delta_score
    ,f.target_size_number
    ,f.current_size_number
    ,f.size_differences
    ,f.current_size
    ,f.recommended_size
    ,f.recommended_action
    ,f.recommendation
    ,f.P50_WH_USED
    ,f.P80_WH_USED
    ,f.P95_WH_USED
    ,f.PCT_JOBS_SPILLED_REMOTE
    ,f.AVG_PCT_WAREHOUSE_USED
    ,c.credits_xp
    //adjustments always assume that queries will take 25-50% longer when we size down. This is due to the fact that concurrency is not taken into account with this calculation, other factors like memory contention and I/O can cause skew, as well as feasibility when combining with other "rocks" at the final FinOps step.
    ,case when (size_differences > 0 AND P80_WH_USED <= 100/(pow(2,size_differences))) THEN pow(.75,size_differences)
          when size_differences > 0 THEN .75 
          ELSE 1
          END as high_adjustment
    ,case when (size_differences > 0 AND P95_WH_USED <= 100/(pow(2,size_differences))) THEN pow(.75,size_differences)
          when size_differences > 0 THEN .75
          ELSE 1          
          END as low_adjustment
    ,sum(c.CREDITS_XP) * RATIO_TO_REPORT(xp_duration*credits_per_hour) OVER (PARTITION BY f.warehouse_id, f.account_id, f.deployment)  as credits
    ,low_adjustment * credits as low_optimized_credits
    ,high_adjustment * credits as high_optimized_credits
FROM {wss_table} f
JOIN {credits_table} c
on f.account_id = c.ACCOUNT_ID
and f.deployment = c.deployment
and f.WAREHOUSE_ID = c.WAREHOUSE_ID
GROUP BY ALL
)

SELECT 
 f.account_id
    ,f.account_name
    ,f.deployment::VARCHAR(50) as deployment
    ,f.warehouse_name
    ,f.warehouse_id
    ,OBJECT_AGG(''Size: '' || f.warehouse_size || '', Type: '' ||  TO_VARCHAR(f.warehouse_type) || '', Resource Constraint: '' || TO_VARCHAR(f.resource_constraint), 
        object_construct(
                ''warehouse_size_score'', f.warehouse_size_score
                ,''associated_credits'',credits::NUMBER(30,4)
                ,''recommended_size'',f.recommended_size
                , ''recommended_action'', f.recommended_action
                ,''recommendation'',f.recommendation
                ,''p80_wh_load'',f.P80_WH_USED
                ,''p95_wh_load'', f.P95_WH_USED
                ,''avg_wh_load'',f.AVG_PCT_WAREHOUSE_USED
                ,''credits_per_hour'',f.credits_per_hour
                )
        )::VARIANT as sizing_details
    ,SUM(DIV0(credits,credits_per_hour)) as billable_hours
    ,SUM(xp_duration)/3600 as execution_hours
    ,SUM(credits) as total_credits
    ,SUM(low_optimized_credits) as total_low_optimized_credits
    ,SUM(high_optimized_credits) as total_high_optimized_credits
    ,ROUND(SUM(P80_WH_USED*credits)/SUM(credits),0) as weighted_p80_wh_load
    ,ROUND(SUM(P95_WH_USED*credits)/SUM(credits),0) as weighted_p95_wh_load
    ,ROUND(SUM(AVG_PCT_WAREHOUSE_USED*credits)/SUM(credits),0) as weighted_avg_wh_load
    ,total_credits-total_low_optimized_credits as estimated_low_credit_savings
    ,total_credits-total_high_optimized_credits as estimated_high_credit_savings
    FROM BASELINE f
    GROUP BY ALL
    );
            """

        # Execute the insert query
        session.sql(INSERT_QUERY).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
