CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.WAREHOUSE_SCORING_STAGING("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_wss'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_wss(session,cust_name: str, deployment_name: str):
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

        # Set deployment & table variables
        deployment = deployment_name.lower()
        dep_schema = deployment.replace("-", "_")
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        job_etl_table = f''SNOWHOUSE_IMPORT.{dep_schema}.JOB_ETL_V''
        wss_table = f''{schema}.WAREHOUSE_SCORING_STAGING'';

        # Insert data into identifier table
        insert_query = f"""
INSERT INTO {wss_table} (
//CREATE OR REPLACE TABLE {wss_table} AS (
with cloud_regions as (
SELECT snowflake_deployment, cloud_provider_region, cloud
FROM  FINANCE.CUSTOMER.SNOWFLAKE_ACCOUNT_REVENUE_LONG 
WHERE date_trunc(''month'',general_date) = ''{previous_month_start}''
and cloud IS NOT NULL
GROUP BY ALL
)
,WAREHOUSE_CREDITS_PER_HOUR AS (
SELECT
 r.server_type_id
 ,cr.cloud
 ,cr.snowflake_deployment
  ,w.warehouse_type
  ,w.resource_constraint
  ,w.size
  ,w.credits_per_hour
FROM
  FINOPS.PRODUCTS.WAREHOUSE_CONSTRAINT_CREDITS w
CROSS JOIN cloud_regions cr 
LEFT JOIN FINOPS.PRODUCTS.RESOURCE_CONSTRAINT_MAPPING_V r 
    on r.warehouse_type = w.warehouse_type
    and r.resource_constraint = w.resource_constraint
WHERE (w.cloud = ''All'' OR cr.cloud = lower(w.cloud))
GROUP BY ALL
)
,wh_kpis as (
select 
job.account_id as account_id
,S.account_name
,''{deployment}'' as deployment
,job.WAREHOUSE_ID
,job.warehouse_name
,job.DPO:"JobDPO:stats":warehouseExternalSize::STRING as WAREHOUSE_S
,MODE(decode(job.stats:stats.warehouseSize::int
            , 1,1
            , 2,2
            , 4,4
            , 8,8
            , 16,16
            , 32,32
            , 64,64
            , 128,128
            , 20,256
            , 40,512
            , null
        )) as  SIZE_NUMBER
,wh_cr.credits_per_hour
,wh_cr.warehouse_type
,wh_cr.resource_constraint
,avg(job.stats:stats.serverCount/job.stats:stats.warehouseSize) as avg_pct_warehouse_used
,sum((job.stats:stats.serverCount/job.stats:stats.warehouseSize)*(dur_xp_executing/1000))/sum(dur_xp_executing/1000) as avg_weighted_pct_wh_used
//,job.DPO:"JobDPO:stats":warehouseExternalSize::STRING as warehouse_size_external 
,max(job.stats:stats.warehouseSize) as warehouse_server_size
,percentile_cont(.90) within group (order by (job.stats:stats.serverCount/job.stats:stats.warehouseSize)) as p90_wh_used
,percentile_cont(.50) within group (order by (job.stats:stats.serverCount/job.stats:stats.warehouseSize)) as p50_wh_used
,percentile_cont(.80) within group (order by (job.stats:stats.serverCount/job.stats:stats.warehouseSize)) as p80_wh_used
,percentile_cont(.95) within group (order by (job.stats:stats.serverCount/job.stats:stats.warehouseSize)) as p95_wh_used
//,percentile_cont(.90) within group (order by ((job.stats:stats.serverCount/job.stats:stats.warehouseSize)*(dur_xp_executing/1000)) as p90_wh_used_weighted
,count(distinct job.uuid) as job_count
,sum(dur_queued_load)/1000 as total_queue_time
,sum(total_duration)/1000 as total_duration
,avg(dur_queued_load/total_duration) as avg_pct_total_queued
,avg(dur_xp_executing)/1000 as avg_xp_duration
,sum(dur_xp_executing)/1000 as xp_duration
,percentile_cont(.50) within group (order by ((job.stats:stats.serverCount/job.stats:stats.warehouseSize)*(dur_xp_executing/1000)))/(sum(dur_xp_executing)/1000) as p50_wh_used_weighted
,percentile_cont(.80) within group (order by ((job.stats:stats.serverCount/job.stats:stats.warehouseSize)*(dur_xp_executing/1000)))/(sum(dur_xp_executing)/1000) as p80_wh_used_weighted
,percentile_cont(.95) within group (order by ((job.stats:stats.serverCount/job.stats:stats.warehouseSize)*(dur_xp_executing/1000)))/(sum(dur_xp_executing)/1000) as p95_wh_used_weighted
,avg(total_duration)/1000 as avg_total_dur
,avg(job.stats:stats.ioRemoteTempWriteBytes)/power(1024, 3) as remote_temp_space_usage
,avg(job.stats:stats.ioLocalTempWriteBytes)/power(1024, 3) as local_temp_space_usage
,sum(case when job.stats:stats.ioRemoteTempWriteBytes is not null then 1 else 0 end) as num_jobs_remote_spilling
,sum(case when job.stats:stats.ioRemoteTempWriteBytes is not null then 1 else 0 end) / job_count as pct_jobs_spilled_remote
 from {job_etl_table} job
 join {scoped_table} S
    on job.account_id = S.account_id
    and S.deployment = ''{deployment}''
left join WAREHOUSE_CREDITS_PER_HOUR as wh_cr
    on wh_cr.snowflake_deployment = ''{deployment}''
    and WAREHOUSE_S = wh_cr.size
    and wh_cr.server_type_id = job.server_type_id
where true
AND warehouse_name not in (''NULL'', ''COMPUTE_SERVICE_WH'', ''COMPUTE_SERVICE_WH_MV'')
and warehouse_name not like ''COMPUTE_SERVICE_WH%''
and job.latest_cluster_number is not null
and job.created_on BETWEEN ''{previous_month_start}'' AND ''{previous_month_end}''
group by ALL),  
cat_scores as (select 
account_id
,account_name
,deployment
,warehouse_name
,WAREHOUSE_ID
,WAREHOUSE_S
,SIZE_NUMBER
,credits_per_hour
,warehouse_type
,resource_constraint
,avg(p50_wh_used) as p50_wh_used
,avg(p80_wh_used) as p80_wh_used
,avg(p95_wh_used) as p95_wh_used
,avg(pct_jobs_spilled_remote) as pct_jobs_spilled_remote
,avg(avg_pct_warehouse_used) as avg_pct_warehouse_used
,sum(xp_duration) as xp_duration
//,wh_kpis.WAREHOUSE_SIZE
  ,case when p90_wh_used < 1 then 100::number end as p90_wh_used_score --if 90 percent of the jobs dont use the full warehosue, pad the score to the to small side
  , (100 - (avg_pct_warehouse_used*100))::number  as avg_wh_used_score --add one point for each avg pct below 100 used
  , case when  avg_xp_duration < 10 then
        ((60 - avg_xp_duration)*2)::number
  else (60 - avg_xp_duration)::number end as xp_dur_score --subtract a point for each second over 60, add a point for each second below 60
  ,-(pct_jobs_spilled_remote*100*2)::number as pct_jobs_spilling_score --add two points for each percentage of jobs with spilling to remote
    from wh_kpis
    GROUP BY ALL),
FINAL as( select account_id
    ,account_name
    ,deployment
    ,warehouse_name
    ,WAREHOUSE_ID
    , WAREHOUSE_S
    , SIZE_NUMBER
    ,credits_per_hour
    ,warehouse_type
    ,resource_constraint
    ,avg(p50_wh_used) as p50_wh_used
    ,avg(p80_wh_used) as p80_wh_used
    ,avg(p95_wh_used) as p95_wh_used
    ,avg(pct_jobs_spilled_remote) as pct_jobs_spilled_remote
    ,avg(avg_pct_warehouse_used) as avg_pct_warehouse_used
    , sum(score) as warehouse_size_score 
    , sum(xp_duration) as xp_duration
    , ceil(warehouse_size_score/75) AS DELTA_SCORE
    , least(
            greatest(
                IFNULL(
                    NULLIF(
                        IFF(
                            DELTA_SCORE >= 2,
                            BITSHIFTRIGHT(SIZE_NUMBER, DELTA_SCORE-2),
                            IFF(
                                DELTA_SCORE >= 0, 
                                SIZE_NUMBER, 
                                IFNULL(
                                    NULLIF(
                                    BITSHIFTLEFT(SIZE_NUMBER, ABS(DELTA_SCORE+1))
                                    ,0)
                                ,512)
                                )
                        )
                    ,0)
                ,1)
            , 1)
        ,512) AS target_size_number
    , size_number as current_size_number
    , CASE WHEN warehouse_size_score < -1000 THEN -100
                    WHEN warehouse_size_score > 1000 THEN 100 
                    WHEN target_size_number = current_size_number THEN 0
                    WHEN warehouse_size_score > 0 AND target_size_number <> current_size_number THEN (current_size_number/target_size_number)/2
                    WHEN warehouse_size_score < 0 AND target_size_number <> current_size_number THEN (target_size_number/current_size_number)/2*-1
               END AS SIZE_DIFFERENCES
    , IFNULL(decode(current_size_number,
                           1,''X-SMALL'',
                           2,''SMALL'',
                           4,''MEDIUM'',
                           8,''LARGE'',
                           16,''X-LARGE'',
                           32,''2X-LARGE'',
                           64,''3X-LARGE'',
                           128,''4X-LARGE'',
                           256,''5X-LARGE'',
                           512,''6X-LARGE''),''--'') AS current_size
    , IFNULL(decode(target_size_number,
                           1,''X-SMALL'',
                           2,''SMALL'',
                           4,''MEDIUM'',
                           8,''LARGE'',
                           16,''X-LARGE'',
                           32,''2X-LARGE'',
                           64,''3X-LARGE'',
                           128,''4X-LARGE'',
                           256,''5X-LARGE'',
                           512,''6X-LARGE''),''--'') AS recommended_size
    , CASE WHEN SIZE_DIFFERENCES IN (-1,-2) THEN CURRENT_SIZE || '' ⬆️ '' || RECOMMENDED_SIZE
                     WHEN SIZE_DIFFERENCES IN (1,2) THEN CURRENT_SIZE || '' ⬇️ '' || RECOMMENDED_SIZE
                     WHEN SIZE_DIFFERENCES = 0 THEN ''✅''
                     WHEN SIZE_DIFFERENCES <> 0 AND CURRENT_SIZE_NUMBER = 1 THEN ''IGNORE''
                     WHEN SIZE_DIFFERENCES > 2 THEN ''SCALE DOWN (REQUIRES MORE ANALYSIS)''
                     WHEN SIZE_DIFFERENCES < -2 THEN ''SCALE UP (REQUIRES MORE ANALYSIS)''
                     ELSE   ''🔍'' 
                END AS RECOMMENDED_ACTION
    , CASE
                     WHEN SIZE_DIFFERENCES IN (-1,-2) THEN ''SCALE UP''
                     WHEN SIZE_DIFFERENCES IN (1,2) THEN ''SCALE DOWN''
                     WHEN SIZE_DIFFERENCES = 0 THEN ''NO RECOMMENDATION''
                     WHEN SIZE_DIFFERENCES <> 0 AND CURRENT_SIZE_NUMBER = 1 THEN ''IGNORE''
                     WHEN SIZE_DIFFERENCES > 2 THEN ''REQUIRES MORE ANALYSIS''
                     WHEN SIZE_DIFFERENCES < -2 THEN ''REQUIRES MORE ANALYSIS''
                     else   ''🔍'' 
                END AS RECOMMENDATION
    from
  cat_scores
      unpivot(score for scores in (p90_wh_used_score, avg_wh_used_score, xp_dur_score, pct_jobs_spilling_score))
group by ALL)
SELECT 
    f.account_id
    ,f.account_name
    ,f.deployment
    ,f.warehouse_name
    ,f.warehouse_id
    ,f.warehouse_s as warehouse_size
    ,f.size_number
    ,f.credits_per_hour
    ,f.warehouse_type
    ,f.resource_constraint
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
    ,(ROUND(p50_wh_used,2) * 100)::INT as p50_wh_used
    ,(ROUND(p80_wh_used,2) * 100)::INT as p80_wh_used
    ,(ROUND(p95_wh_used,2) * 100)::INT as p95_wh_used
    ,(ROUND(pct_jobs_spilled_remote,2) * 100)::INT as pct_jobs_spilled_remote
    ,(ROUND(avg_pct_warehouse_used,2) * 100)::INT as avg_pct_warehouse_used
FROM FINAL f
GROUP BY ALL
)
;
        """

        # Execute the CTAS query
        session.sql(insert_query).collect()

        return ''Data Inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
