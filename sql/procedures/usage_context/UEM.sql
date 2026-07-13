CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.UEM("CUST_NAME" VARCHAR, "DEPLOYMENT_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_uem'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_uem(session,cust_name: str, deployment_name: str):
    try:
        # Define and set variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''
        ue_table = f''{schema}.UEM''

        # Current quarter start date
        current_quarter_start_date = session.sql("SELECT date_trunc(''quarter'', current_date())").collect()[0][0]
        current_quarter_start_date = current_quarter_start_date.strftime(''%Y-%m-%d'')

        # End of Previous Month
        previous_month_end = session.sql("SELECT DATEADD(''day'',-1,DATE_TRUNC(''month'',CURRENT_DATE()))").collect()[0][0]
        previous_month_end = previous_month_end.strftime(''%Y-%m-%d'')

        # Two years prior beginning date
        prior_two_years_beginning_date = session.sql(f"SELECT dateadd(year, -2, dateadd(month, -3, ''{current_quarter_start_date}''::DATE))").collect()[0][0]
        prior_two_years_beginning_date = prior_two_years_beginning_date.strftime(''%Y-%m-%d'')

        # Set deployment variables
        deployment = deployment_name.lower()
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        
        # --- START: NEW DS LOGIC ---
        # Insert data into identifier table
        insert_query = f"""
            INSERT INTO {ue_table} (
                PERIOD,
                MONTH,
                ACCOUNT_ID,
                DEPLOYMENT,
                XP_JOBS,
                DUR_XP_EXECUTING,
                CPU_HOURS,
                AVG_CONCURRENCY,
                TOTAL_DURATION,
                PRODUCED_ROWS,
                BYTES_SPILLED,
                BYTES_WRITTEN,
                BYTES_SCANNED,
                ACTIVE_USERS,
                USED_DATABASE,
                USED_SCHEMA,
                USED_WAREHOUSE
            )
            WITH
              warehouse_data AS (
                SELECT
                  f.ACCOUNT_ID,
                  f.DEPLOYMENT,
                  YEAR(DS) || ''-Q'' || QUARTER(DS) AS PERIOD,
                  DATE_TRUNC(''MONTH'', DS) AS "MONTH",
                  SUM(XP_JOBS) AS xp_jobs,
                  SUM(COALESCE(state_durations:dur_xp_executing::double, 0)) AS dur_xp_executing,
                  SUM(COALESCE(state_durations:dur_xp_executing::double, 0)) / 3600 / 1000 AS CPU_HOURS,
                  null as AVG_CONCURRENCY,
                  null as TOTAL_DURATION,
                  SUM(COALESCE(stats:producedRows::double, 0)) as producedRows,
                  SUM(coalesce(stats:ioLocalTempWriteBytes,0))+SUM(coalesce(stats:ioRemoteTempWriteBytes,0)) as BYTES_SPILLED,
                  SUM(coalesce(stats:ioRemoteFdnWriteBytes::number, 0)) as BYTES_WRITTEN,
                  SUM(COALESCE(stats:ioLocalFdnReadBytes::double, 0)) + SUM(COALESCE(stats:ioRemoteFdnReadBytes::double, 0)) :: INT AS BYTES_SCANNED,
                  COUNT(DISTINCT f.account_id || f.warehouse_name) AS nb_WH
                FROM
                  snowscience.job_analytics.daily_warehouse_job_stats AS f
                  JOIN {scoped_table} AS map ON f.ACCOUNT_ID = map.ACCOUNT_ID
                  AND f.DEPLOYMENT = map.deployment
                WHERE
                  f.DS::DATE BETWEEN ''{prior_two_years_beginning_date}'' AND ''{previous_month_end}''
                  AND WAREHOUSE_ID NOT IN (0, -2)
                  AND f.WAREHOUSE_NAME NOT LIKE ''COMPUTE_SERVICE_WH_%''
                  AND f.deployment = ''{deployment}''
                GROUP BY
                  ALL
              ),
              user_schema_data AS (
                SELECT
                  f.ACCOUNT_ID,
                  f.DEPLOYMENT,
                  YEAR(DS) || ''-Q'' || QUARTER(DS) AS PERIOD,
                  DATE_TRUNC(''MONTH'', DS) AS "MONTH",
                  COUNT(DISTINCT f.user_id) AS nb_users,
                  COUNT(DISTINCT f.account_id || database_id) AS nb_DB,
                  COUNT(DISTINCT f.account_id || s.schema_name) AS nb_SCHEMA
                FROM
                  snowscience.job_analytics.job_distinct_entities_for_finops AS f
                  JOIN {scoped_table} AS map ON f.ACCOUNT_ID = map.ACCOUNT_ID
                  AND f.DEPLOYMENT = map.deployment
                  JOIN (
                    SELECT DISTINCT
                      account_id,
                      deployment,
                      warehouse_id,
                      warehouse_name
                    FROM
                      snowscience.job_analytics.daily_warehouse_job_stats
                  ) AS d ON f.account_id = d.account_id
                  AND f.deployment = d.deployment
                  AND f.warehouse_id = d.warehouse_id
                  LEFT JOIN (
                    SELECT DISTINCT
                      account_id,
                      deployment,
                      id,
                      name as schema_name
                    FROM
                      snowhouse_import.prod.schema_etl_v
                  ) AS s ON f.account_id = s.account_id
                  AND f.deployment = s.deployment
                  AND f.schema_id = s.id
                WHERE
                  f.DS::DATE BETWEEN ''{prior_two_years_beginning_date}'' AND ''{previous_month_end}''
                  AND d.WAREHOUSE_ID NOT IN (0, -2)
                  AND d.WAREHOUSE_NAME NOT LIKE ''COMPUTE_SERVICE_WH_%''
                  AND f.deployment = ''{deployment}''
                GROUP BY
                  ALL
              )
            SELECT
              w.PERIOD as PERIOD,
              W.MONTH as MONTH,
              W.ACCOUNT_ID as ACCOUNT_ID,
              w.DEPLOYMENT as DEPLOYMENT,
              w.XP_JOBS::float as XP_JOBS,
              w.dur_xp_executing::float as dur_xp_executing,
              w.CPU_HOURS::float as CPU_HOURS,
              w.AVG_CONCURRENCY::float as AVG_CONCURRENCY,
              w.TOTAL_DURATION::float as TOTAL_DURATION, 
              w.producedRows::float as producedRows,
              w.BYTES_SPILLED::float as BYTES_SPILLED,
              w.BYTES_WRITTEN::float as BYTES_WRITTEN,
              w.BYTES_SCANNED::float as BYTES_SCANNED,  
              us.nb_users::float as ACTIVE_USERS,
              us.nb_db::float as USED_DATABASE,
              us.nb_schema::float as USED_SCHEMA,
              w.nb_WH::float as USED_WAREHOUSE
            FROM
              warehouse_data AS w
              LEFT JOIN user_schema_data AS us ON w.account_id = us.account_id
              AND w.deployment = us.DEPLOYMENT
              AND w.PERIOD = us.PERIOD
              AND w.Month = us.month;
            -- --- END: NEW DS LOGIC ---
        """

        # Execute the insert query
        session.sql(insert_query).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
