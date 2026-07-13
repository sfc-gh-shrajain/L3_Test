CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.OTHER_VIEWS("CUST_NAME" VARCHAR)
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
        sfdc_accounts = f''{schema}.SFDC_ACCOUNTS''
        snowpipe_pipe_analysis = f''{schema}.SNOWPIPE_PIPE_ANALYSIS''
        snowpipe_pipe_savings = f''{schema}.SNOWPIPE_PIPE_SAVINGS''
        snowpipe_account_agg = f''{schema}.SNOWPIPE_ACCOUNT_AGG''
        auto_cluster_analysis = f''{schema}.AUTO_CLUSTER_ANALYSIS''
        auto_cluster_account_agg = f''{schema}.AUTO_CLUSTER_ACCOUNT_AGG''
        other_agg = f''{schema}.OTHER_ACCOUNT_AGG''
        cloud_services_wh = f''{schema}.CLOUD_SERVICES_WHS''
        cloud_services_recommendations =  f''{schema}.CLOUD_SERVICES_RECOMMENDATIONS''
        cloud_services_queries =  f''{schema}.CLOUD_SERVICES_QUERIES''
        attributed_cost_query_history_30d = f''{schema}.ATTRIBUTED_COST_QUERY_HISTORY_30D''
        warehouse_credits = f''{schema}.WAREHOUSE_CREDITS''
        query_history_30d = f''{schema}.QUERY_HISTORY_30D''
        cloud_services_account_agg = f''{schema}.CLOUD_SERVICES_ACCOUNT_AGG''
        billing_table = f''{schema}.BILLING''
        
        

        # Days in Month
        days_in_previous_month = session.sql("SELECT DAY(DATEADD(''day'',-1, DATE_TRUNC(''month'',CURRENT_DATE())))").collect()[0][0]
        
    # Create snowpipe pipe analysis query View
        SNOWPIPE_PIPE_SAVINGS_CVA = f"""
        CREATE OR REPLACE VIEW {snowpipe_pipe_savings} AS (
            //need to validate the amount in savings for adjusting file sizes. Currently set at a conservative 25%
            SELECT
            c.account_id
            ,c.deployment
            ,c.table_name
            ,c.pipe_name
            ,c.total_files 
            ,c.pipe_runs as pipe_hour_runs
            ,sum_credits_files
            ,percent_files
            ,sum_credits_wh
            ,c.avg_file_size_mb
            ,c.max_file_size_mb
            ,c.min_file_size_mb
            ,stddev_file_size_mb
            ,c.total_file_size_mb
            ,c.std_diff_from_mean
            ,c.file_over_250mb
            ,c.file_under_100mb
            ,c.file_under_10mb
            ,c.p50_filze_size
            ,c.p80_filze_size
            ,c.p95_filze_size
            ,SUM(CASE WHEN 
            (file_over_250mb + file_under_10mb)/total_files >= .95
            THEN sum_credits_wh 
            ELSE 0 END)  as low_credits_loading
            ,SUM(CASE WHEN 
            (file_over_250mb + file_under_10mb)/total_files >= .8
            THEN sum_credits_wh
            ELSE 0 END) as high_credits_loading
            ,(total_file_size_mb/10)/1000 *.06 as estimated_high_file_cost
            ,(total_file_size_mb/250)/1000 *.06 as estimated_low_file_cost
            ,CASE WHEN estimated_high_file_cost < sum_credits_files THEN sum_credits_files - estimated_high_file_cost ELSE 0 END as low_credits_file_num_savings
            ,CASE WHEN estimated_low_file_cost < sum_credits_files THEN sum_credits_files - estimated_low_file_cost ELSE 0 END as high_credits_file_num_savings
            ,SUM(sum_credits) as total_table_loading_credits
            ,total_table_loading_credits/(total_file_size_mb/1024/1024) as credits_per_tb_loaded
            ,case 
            when std_diff_from_mean > .34 AND NOT(p95_filze_size BETWEEN 10 and 250) AND credits_per_tb_loaded > 25 THEN .5
                WHEN std_diff_from_mean > .34 AND NOT(p80_filze_size BETWEEN 10 and 250) AND credits_per_tb_loaded > 25 THEN .4
                WHEN std_diff_from_mean > .34 and credits_per_tb_loaded > 25 THEN .3
                ELSE .25
                END as potential_savings_file_size
            ,low_credits_loading*potential_savings_file_size + low_credits_file_num_savings as low_credits_potential_savings
            ,high_credits_loading*potential_savings_file_size + high_credits_file_num_savings as high_credits_potential_savings
            FROM {snowpipe_pipe_analysis} c
            JOIN {sfdc_accounts} s 
            on s.snowflake_account_id = c.account_id 
            and s.snowflake_deployment = c.deployment
            WHERE 
                total_file_size_mb > 1024 //at least 1 GB loaded across the last month
                //and total_files > (30) //at least 1 file a day 
                and 1 = 0 //removing insight all-together as snowpipe has moved to a cost per TB model. Need to spend time to get rid of these views as a whole eventually. 
                //service_level NOT IN (''BUSINESS_CRITICAL'',''VPS'') //removed cases where new pricing has gone into effect
            GROUP BY ALL
            )
            ;
        """
    # Create snowpipe account agg analysis query View
        SNOWPIPE_ACCOUNT_CVA = f"""
        CREATE OR REPLACE VIEW {snowpipe_account_agg} AS (
            //need to validate the amount in savings for adjusting file sizes. Currently set at a conservative 25%
            SELECT
            c.account_id
            ,c.deployment
            ,SUM(file_over_250mb + file_under_10mb)/SUM(total_files) as file_percent_not_10_to_250mb
            ,SUM(total_files) as total_files
            ,SUM(total_file_size_mb)/SUM(total_files) as avg_file_size_mb
            ,MEDIAN(p50_filze_size) as median_pipe_file_size
            ,SUM(total_file_size_mb)/1024/1024 as tb_loaded
            ,SUM(total_table_loading_credits) as table_loading_credits
            ,table_loading_credits/(tb_loaded) as credits_per_tb_loaded
            ,sum(sum_credits_files) as credits_files
            ,sum(sum_credits_wh) as credits_wh
            ,(credits_files/(credits_files+credits_wh)) as credit_percent_files
            ,SUM(low_credits_loading) as total_low_credits_loading
            ,SUM(high_credits_loading) as total_high_credits_loading
            ,SUM(low_credits_file_num_savings) as total_low_credits_file_num_savings
            ,SUM(high_credits_file_num_savings) as total_high_credits_file_num_savings
            ,AVG(potential_savings_file_size) as avg_potential_savings_file_size
            ,SUM(low_credits_potential_savings) as total_low_credit_potential_savings
            ,SUM(high_credits_potential_savings) as total_high_credit_potential_savings
            FROM {snowpipe_pipe_savings} c
            WHERE true 
            GROUP BY ALL
            )
            ;
        """
        
        # Create Auto Cluster Account Analysis
        AUTOCLUSTER_CVA = f"""
        CREATE OR REPLACE VIEW {auto_cluster_account_agg} AS (
        SELECT 
        account_id
        ,deployment
        ,SUM(CASE WHEN PERCENT_RECLUSTERED > 400 THEN 
        TOTAL_RECLUSTER_CREDITS * (365/{days_in_previous_month}) * .5 ELSE 0 END) AS low_autocluster_annual_credit_savings
        ,SUM(CASE WHEN PERCENT_RECLUSTERED > 40 THEN 
        TOTAL_RECLUSTER_CREDITS * (365/{days_in_previous_month}) * .5 ELSE 0 END) AS high_autocluster_annual_credit_savings
        FROM {auto_cluster_analysis}
        WHERE true
        and gb_reclustered > 100
        and total_recluster_credits > 50
        GROUP BY ALL
        )
        ;
        """

        # Create HIGH CLOUD SERVICES WAREHOUSES
        CLOUD_SERVICES_WAREHOUSES_CVA = f"""
        CREATE OR REPLACE VIEW {cloud_services_wh} AS (
        WITH WH_NON_CREDITS AS (
        SELECT
        account_id
        ,deployment
        ,warehouse_name
        ,SUM(credits_attributed_compute) as attributed_credits
        ,SUM(cloud_services_credits) as cloud_services_credits_total
        FROM {attributed_cost_query_history_30d} qac
        GROUP BY ALL
        )
        ,WH_CREDITS AS (
        SELECT
        account_id
        ,deployment
        ,warehouse_name
        ,month
        ,SUM(credits_xp) as total_credits
        FROM {warehouse_credits} c
        GROUP BY ALL
        )
        SELECT 
        c.account_id
        ,c.deployment
        ,s.account_name
        ,c.warehouse_name
        ,c.month
        ,total_credits
        ,attributed_credits
        ,cloud_services_credits_total
        ,DIV0(cloud_services_credits_total,total_credits) * 100 as cloud_services_credits_perc
        ,DIV0(cloud_services_credits_total, attributed_credits) * 100 as cloud_services_credits_perc_efficiency
        ,100 * RATIO_TO_REPORT(cloud_services_credits_total) OVER (PARTITION BY c.account_id, c.deployment) as PERC_OF_TOTAL_CLOUD_SERVICES
        ,100 * RATIO_TO_REPORT(total_credits) OVER (PARTITION BY c.account_id, c.deployment) as PERC_OF_TOTAL_CREDITS
        ,PERC_OF_TOTAL_CLOUD_SERVICES - PERC_OF_TOTAL_CREDITS as OUTSIZED_CLOUD_COSTS
        FROM WH_CREDITS c
        LEFT JOIN WH_NON_CREDITS nc 
            on c.account_id = nc.account_id
            and c.deployment = nc.deployment
            and c.warehouse_name = nc.warehouse_name
        LEFT JOIN {scoped_table} s
            on s.account_id = c.account_id
            and s.deployment = c.deployment
        WHERE cloud_services_credits_total >  0
        QUALIFY OUTSIZED_CLOUD_COSTS > 1
        )
        ;
        """

        # Create HIGH CLOUD SERVICES QUERIES
        CLOUD_SERVICES_QUERIES_CVA = f"""
        CREATE OR REPLACE VIEW {cloud_services_queries} AS (
        SELECT 
        qh.account_id
        ,qh.deployment
        ,qh.warehouse_name
        ,QUERY_PARAMETERIZED_HASH
        //,LISTAGG(DISTINCT SCHEMA_NAME, '','') as SCHEMAS
        ,STATEMENT_TYPE as query_type
        ,case
                when query_type in (
                  ''CREATE_TABLE'',''ALTER_TABLE'',''DROP_TABLE'',
                  ''CREATE_SCHEMA'',''ALTER_SCHEMA'',''DROP_SCHEMA'',
                  ''CREATE_VIEW'',''ALTER_VIEW'',''DROP_VIEW'',
                  ''CREATE_DATABASE'',''ALTER_DATABASE'',''DROP_DATABASE''
                ) then ''DDL''
                when query_type like ''SHOW%'' then ''SHOW''
                when query_type = ''COPY''     then ''COPY''
                when query_type = ''INSERT''   then ''INSERT''
                when query_type = ''SELECT''   then ''SELECT''
                else ''OTHER''
              end as q_category
              /* clone detection via CREATE ... CLONE keyword */
              ,SUM(case when q_category = ''DDL''
               and description like ''% CLONE %'' THEN 1 ELSE 0 END) as q_is_clone_num
            ,SUM(CASE WHEN description like ''%INFORMATION_SCHEMA%'' OR SCHEMA_NAME = ''INFORMATION_SCHEMA'' THEN 1 ELSE 0 END) as count_is_in_query
            ,LISTAGG(DISTINCT qh.WAREHOUSE_NAME, '','') as warehouses_used
            ,MAX(description) AS SAMPLE_QUERY_TEXT
            ,COUNT(*) AS CALLS
            ,SUM(cloud_services_credits_used) AS TOTAL_CLOUD_SERVICES_CREDITS
            ,SUM(TRANSACTION_BLOCKED)/1000/3600 AS TOTAL_TRANSACTION_BLOCKED_HRS
            ,SUM(LIST_EXTERNAL_FILES_TIME)/1000/3600 AS TOTAL_EXTERNAL_FILE_LISTING_HRS
            ,SUM(COMPILING_SEC)/3600 AS TOTAL_COMPILATION_HRS
            ,SUM(EXECUTING_SEC)/3600 as TOTAL_EXECUTION_HRS
            ,SUM(DURATION_SEC)/3600 as TOTAL_ELAPSED_HRS
            ,SUM(QUEUED_SEC)/3600 as TOTAL_QUEUEING_HRS
            ,SUM(GS_EXECUTING_SEC)/3600 as TOTAL_GS_EXECUTING_HRS
            ,TOTAL_EXECUTION_HRS - TOTAL_GS_EXECUTING_HRS as non_gs_execution_hrs
            ,100 * RATIO_TO_REPORT(TOTAL_CLOUD_SERVICES_CREDITS) OVER (PARTITION BY qh.account_id, qh.deployment, qh.warehouse_name) as PERC_OF_TOTAL_CLOUD_SERVICES
            ,SUM(ROWS_INSERTED) as ROWS_INSERTED
            ,SUM(ROWS_PRODUCED) as ROWS_PRODUCED
            ,SUM(BYTES_SCANNED)/pow(1024,3) as GB_SCANNED
            ,SUM(BYTES_SCANNED)/pow(1024,3)/CALLS as GB_SCANNED_PER_QUERY
            ,TOTAL_ELAPSED_HRS*3600/CALLS as AVG_QUERY_DURATION_SEC
            ,SUM(ROWS_INSERTED)/CALLS as avg_rows_inserted
        FROM {query_history_30d} qh
        JOIN {cloud_services_wh} hc
            on qh.account_id = hc.account_id
            and qh.deployment = hc.deployment
            and qh.warehouse_name = hc.warehouse_name
        WHERE 1 = 1
        //AND qh.WAREHOUSE_NAME = ''PROMOTION_WH''
        GROUP BY ALL
        //ORDER BY TOTAL_CLOUD_SERVICES_CREDITS DESC
       // limit 200
        )
        ;
        """

        
        # Create HIGH CLOUD SERVICES RECOMMENDATIONS
        CLOUD_SERVICES_RECOMMENDATIONS_CVA = f"""
        CREATE OR REPLACE VIEW {cloud_services_recommendations} AS (
        WITH params as (
              select
                50::int     as top_n,
                0.20::float as high_cs_pct,
                0.10::float as high_copy_ratio,
                0.15::float as high_ddl_ratio,
                0.15::float as high_is_ratio,
                0.15::float as high_show_ratio,
                0.40::float as high_simple_ratio,
                0.40::float as high_single_row_insert_ratio,
                0.15::float as high_comp_ratio
        )
        ,WH_AGG AS (
          select
            account_id
            ,deployment
            ,warehouse_name
            /* categorized statement counts using Snowflake''s capital QUERY_TYPE values */
            ,sum(case when q_category = ''SHOW''   then calls else 0 end) as num_show_commands
            ,sum(case when count_is_in_query >= 1 then calls else 0 end) as num_is_queries
            ,sum(case when q_category = ''COPY''   then calls else 0 end) as num_copy_commands
            ,sum(case when q_category = ''DDL''    then calls else 0 end) as num_ddl_ops
            ,sum(case when q_category = ''INSERT'' then calls else 0 end) as num_insert_stmts
        
            /* NEW: explicit clone operations (CREATE ... CLONE ...) */
            ,sum(q_is_clone_num) as num_clone_ops
        
            /* totals */
            ,sum(calls) as num_queries
            //,SUM(count_is_in_query) as is_query_count
        
                /* heuristics */
            ,sum(case when q_category = ''INSERT'' AND calls = rows_inserted THEN CALLS else 0 end) as num_single_row_inserts
            ,sum(case when q_category = ''SELECT'' and gb_scanned = 0 and rows_produced <= calls then calls else 0 end) as num_simple_selects
        
        
            /* categorize statement cloud cost using the same logic */
            ,sum(case when q_category = ''SHOW''   then TOTAL_CLOUD_SERVICES_CREDITS else 0 end) as cs_show_commands
            ,sum(case when count_is_in_query > 0 then TOTAL_CLOUD_SERVICES_CREDITS else 0 end) as cs_is_queries_schemas
            ,sum(case when q_category = ''COPY''   then TOTAL_CLOUD_SERVICES_CREDITS else 0 end) as cs_copy_commands
            ,sum(case when q_category = ''DDL''    then TOTAL_CLOUD_SERVICES_CREDITS else 0 end) as cs_ddl_ops
            ,sum(case when q_category = ''INSERT'' then TOTAL_CLOUD_SERVICES_CREDITS else 0 end) as cs_insert_stmts
            ,sum(case when q_category = ''DDL''  AND q_is_clone_num > 0  then TOTAL_CLOUD_SERVICES_CREDITS else 0 end) as cs_cloning
        
        
            /* heuristics credits */
            ,sum(case when q_category = ''INSERT'' and calls = rows_inserted then TOTAL_CLOUD_SERVICES_CREDITS else 0 end) as cs_single_row_inserts
            ,sum(case when q_category = ''SELECT'' and gb_scanned = 0 and rows_produced <= calls then TOTAL_CLOUD_SERVICES_CREDITS else 0 end) as cs_simple_selects
            ,SUM(case when count_is_in_query > 0 THEN TOTAL_CLOUD_SERVICES_CREDITS else 0 end ) as cs_is_query
            ,SUM(case when q_category NOT IN (''SHOW'',''COPY'',''DDL'') AND TOTAL_COMPILATION_HRS > 0 THEN TOTAL_CLOUD_SERVICES_CREDITS ELSE 0 END ) as cs_compilation_all
        
            /* timings retained for ratios) */
                ,SUM(TOTAL_CLOUD_SERVICES_CREDITS) AS TOTAL_CLOUD_SERVICES_CREDITS
                ,SUM(TOTAL_TRANSACTION_BLOCKED_HRS) AS TOTAL_TRANSACTION_BLOCKED_HRS
                ,SUM(TOTAL_EXTERNAL_FILE_LISTING_HRS) AS TOTAL_EXTERNAL_FILE_LISTING_HRS
                ,SUM(TOTAL_COMPILATION_HRS) AS TOTAL_COMPILATION_HRS
                ,SUM(TOTAL_EXECUTION_HRS) as TOTAL_EXECUTION_HRS
                ,SUM(TOTAL_ELAPSED_HRS) as TOTAL_ELAPSED_HRS
                ,SUM(TOTAL_QUEUEING_HRS) as TOTAL_QUEUEING_HRS
                ,SUM(TOTAL_GS_EXECUTING_HRS) as TOTAL_GS_EXECUTING_HRS
                ,SUM(GB_SCANNED) as GB_SCANNED
            /* schema breadth + scan density */
            ,sum(gb_scanned) / nullif(sum(calls), 0) as avg_gb_scanned_per_query
          from {cloud_services_queries}
          GROUP BY ALL
        )
        
        select
        w.account_id
        ,w.deployment
        ,w.warehouse_name
          ,round(w.cloud_services_credits_total, 3)      as cs_credits
          ,round(w.total_credits, 3) as compute_credits
          ,round(w.cloud_services_credits_perc, 3)          as cs_pct
          ,round(w.PERC_OF_TOTAL_CLOUD_SERVICES,2) as CS_PCT_OF_ACCOUNT
          ,w.month
        
          ,q.num_queries
          ,q.num_copy_commands
          ,q.num_ddl_ops - num_clone_ops as num_ddl_ops_only
          ,q.num_is_queries
          ,q.num_show_commands
          ,q.num_insert_stmts
          ,q.num_single_row_inserts
          ,q.num_simple_selects
          ,q.num_clone_ops
        
             /* categorize statement cloud cost using the same logic */
            ,q.cs_show_commands
          //  ,q.cs_is_queries_schemav --former logic for is. disregarded because Information_schema are commonly queried outside of your context set in this schema. Ideally - would include both together.
            ,q.cs_copy_commands
            ,q.cs_ddl_ops - q.cs_cloning as cs_ddl_ops_only
            ,q.cs_insert_stmts
            ,q.cs_cloning
        
        
            /* heuristics credits */
            ,q.cs_single_row_inserts
            ,q.cs_simple_selects
            ,q.cs_is_query
            ,q.cs_compilation_all - cs_single_row_inserts - cs_simple_selects - cs_is_query as cs_compilation
        
          ,round(q.TOTAL_COMPILATION_HRS / nullif(q.TOTAL_ELAPSED_HRS, 0), 3) as compilation_ratio
          ,round(q.GB_SCANNED, 2) / num_queries  as avg_gb_scanned
        
          /* Recommendation flags */
          /*
          ,iff(cs_pct >= (select high_cs_pct from params),
              ''High CS%: audit serverless and metadata-heavy patterns'', null) as rec_high_cs_pct
              */
          ,iff(q.num_copy_commands / nullif(q.num_queries,0) >= (select high_copy_ratio from params)
              ,''COPY: use prefix/date partitioning; list fewer files'', null) as rec_copy_selectivity
          ,iff((q.num_ddl_ops - q.num_clone_ops) / nullif(q.num_queries,0) >= (select high_ddl_ratio from params),
              ''High DDL frequency: reduce cadence'', null) as rec_ddl_frequency
          ,iff(q.num_clone_ops / nullif(q.num_queries,0) >= (select high_ddl_ratio from params),
              ''Frequent CLONE operations: review clone cadence and scope'', null) as rec_clone_frequency
          ,iff(q.num_simple_selects / nullif(q.num_queries,0) >= (select high_simple_ratio from params),
              ''Simple queries at high frequency: lower polling; use getSessionId()'', null) as rec_simple_queries
          ,iff(q.num_is_queries / nullif(q.num_queries,0) >= (select high_is_ratio from params),
              ''High INFORMATION_SCHEMA usage: prefer ACCOUNT_USAGE or cache results'', null) as rec_information_schema
          ,iff(q.num_show_commands / nullif(q.num_queries,0) >= (select high_show_ratio from params),
              ''Frequent SHOW commands: reduce cadence or adjust tooling'', null) as rec_show_frequency
          ,iff(q.num_insert_stmts > 0 and q.num_single_row_inserts / nullif(q.num_insert_stmts,0) >= (select high_single_row_insert_ratio from params),
              ''Single-row inserts: batch/bulk load; consolidate fragmented schemas'', null) as rec_single_row_inserts
          ,iff(nullif(compilation_ratio, 0) >= (select high_comp_ratio from params),
              ''High compilation: simplify SQL; parameterize/reuse'', null) as rec_high_compilation
        
        /* Cloud Cost Impact */
        /*
          ,iff(cs_pct >= (select high_cs_pct from params),
              cs_credits, null) as cs_credits_high
              */
          ,iff(q.num_copy_commands / nullif(q.num_queries,0) >= (select high_copy_ratio from params),
              cs_copy_commands, null) as cs_copy_selectivity
          ,iff((q.num_ddl_ops - q.num_clone_ops) / nullif(q.num_queries,0) >= (select high_ddl_ratio from params),
              cs_ddl_ops - cs_cloning, null) as cs_ddl_frequency
          ,iff(q.num_clone_ops / nullif(q.num_queries,0) >= (select high_ddl_ratio from params),
              cs_cloning, null) as cs_clone_frequency
          ,iff(q.num_simple_selects / nullif(q.num_queries,0) >= (select high_simple_ratio from params),
              cs_simple_selects, null) as cs_simple_queries
          ,iff(q.num_is_queries / nullif(q.num_queries,0) >= (select high_is_ratio from params),
              cs_is_query, null) as cs_information_schema
          ,iff(q.num_show_commands / nullif(q.num_queries,0) >= (select high_show_ratio from params),
              cs_show_commands, null) as cs_show_frequency
          ,iff(q.num_insert_stmts > 0 and q.num_single_row_inserts / nullif(q.num_insert_stmts,0) >= (select high_single_row_insert_ratio from params),
             cs_single_row_inserts, null) as cs_single_row_inserts_frequency
          ,iff(nullif(compilation_ratio, 0) >= (select high_comp_ratio from params),
              cs_compilation, null) as cs_high_compilation
        ,IFNULL(cs_copy_selectivity,0) + IFNULL(cs_ddl_frequency,0) + IFNULL(cs_clone_frequency,0) + IFNULL(cs_simple_queries,0) + IFNULL(cs_information_schema,0) + IFNULL(cs_show_frequency,0) + IFNULL(cs_single_row_inserts_frequency,0) + IFNULL(cs_high_compilation,0) as addressable_cs
        from {cloud_services_wh} w
        left join wh_agg q 
            on q.warehouse_name = w.warehouse_name
            and q.account_id = w.account_id
            and q.deployment = w.deployment
        where 1 = 1
        )
        ;
        """
         
         # Create HIGH CLOUD SERVICES QUERIES
        CLOUD_SERVICES_ACCOUNT_AGG_CVA = f"""
        CREATE OR REPLACE VIEW {cloud_services_account_agg} AS (
        WITH CS_AGG AS ( 
            SELECT 
            r.account_id
            ,r.deployment
            ,r.month
            ,SUM(cs_copy_selectivity) as copy_selectivity
            ,SUM(cs_ddl_frequency) as ddl_frequency
            ,SUM(cs_clone_frequency) as clone_frequency
            ,SUM(cs_simple_queries) as simple_queries
            ,SUM(cs_information_schema) as information_schema
            ,SUM(cs_show_frequency) as show_frequency
            ,SUM(cs_single_row_inserts_frequency) as single_row_inserts_frequency
            ,SUM(cs_high_compilation) as high_compilation
            ,SUM(addressable_cs) as cs_to_optimize
            FROM {cloud_services_recommendations} r
            GROUP BY ALL
        )
        SELECT 
            c.account_id
            ,c.deployment
            ,copy_selectivity
            ,ddl_frequency
            ,clone_frequency
            ,simple_queries
            ,information_schema
            ,show_frequency
            ,single_row_inserts_frequency
            ,high_compilation
            ,cs_to_optimize
            ,credits as total_addressible_credits
        ,CASE 
            WHEN total_addressible_credits >= cs_to_optimize THEN cs_to_optimize
            ELSE total_addressible_credits
        END as cloud_credits_eligible_to_optimize
        
        //reduction of cloud costs by 60-80% with investigation. Largely due to changing data pipeline process or reduction of frequency.
        ,ROUND(cloud_credits_eligible_to_optimize * 0.6 ,2) as low_cloud_services_credit_savings
        ,ROUND(cloud_credits_eligible_to_optimize * 0.8 ,2) as high_cloud_services_credit_savings
        FROM CS_AGG c
        left join {billing_table} b
            on c.account_id = b.account_id
            and c.deployment = b.deployment
            and c.month = b.month
            and b.revenue_category = ''Cloud Services''
        GROUP BY ALL
        );
        """

    # Create Other AGG Analysis 
        OTHER_AGG_CVA = f"""
        CREATE OR REPLACE VIEW {other_agg} AS (
        SELECT 
        a.account_id
        ,a.deployment
        ,a.locator
        ,a.account_name
        
        //snowpipe
        ,total_low_credit_potential_savings * (365/{days_in_previous_month}) as low_snowpipe_annual_credit_savings
        ,total_high_credit_potential_savings * (365/{days_in_previous_month}) as high_snowpipe_annual_credit_savings
        ,low_snowpipe_annual_credit_savings * c.price_per_credit as low_snowpipe_annual_dollar_savings
        ,high_snowpipe_annual_credit_savings * c.price_per_credit as high_snowpipe_annual_dollar_savings
        
        //auto-clustering
        ,low_autocluster_annual_credit_savings 
        ,high_autocluster_annual_credit_savings
        ,low_autocluster_annual_credit_savings * c.price_per_credit as low_autocluster_annual_dollar_savings
        ,high_autocluster_annual_credit_savings * c.price_per_credit as high_autocluster_annual_dollar_savings
        
        //cloud services
        ,low_cloud_services_credit_savings * (365/{days_in_previous_month}) as low_cloud_services_annual_credit_savings
        ,high_cloud_services_credit_savings * (365/{days_in_previous_month}) as high_cloud_services_annual_credit_savings
        ,low_cloud_services_annual_credit_savings * c.price_per_credit as low_cloud_services_annual_dollar_savings
        ,high_cloud_services_annual_credit_savings * c.price_per_credit as high_cloud_services_annual_dollar_savings
        FROM {scoped_table} a
        LEFT JOIN  {snowpipe_account_agg} s
            on a.account_id = s.account_id
            and a.deployment = s.deployment
        LEFT JOIN  {auto_cluster_account_agg} ac
            on a.account_id = ac.account_id
            and a.deployment = ac.deployment
        LEFT JOIN  {cloud_services_account_agg} cs
            on a.account_id = cs.account_id
            and a.deployment = cs.deployment
        LEFT JOIN  {cost_table} c
            on a.account_id = c.account_id
            and a.deployment = c.deployment
        WHERE true
        GROUP BY ALL
        )
        ;
        """
        
        

 # Execute the view queries
        session.sql(SNOWPIPE_PIPE_SAVINGS_CVA).collect()
        session.sql(SNOWPIPE_ACCOUNT_CVA).collect()
        session.sql(AUTOCLUSTER_CVA).collect()
        session.sql(CLOUD_SERVICES_WAREHOUSES_CVA).collect()
        session.sql(CLOUD_SERVICES_QUERIES_CVA).collect()
        session.sql(CLOUD_SERVICES_RECOMMENDATIONS_CVA).collect()
        session.sql(CLOUD_SERVICES_ACCOUNT_AGG_CVA).collect()
        session.sql(OTHER_AGG_CVA).collect()
        
        return ''Views created successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
