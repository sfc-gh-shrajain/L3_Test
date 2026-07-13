CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.SP_BUILD_INTRA_MONTH_WH("SCHEMA_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
EXECUTE AS OWNER
AS '
    var tableName   = ''FINOPS_OUTPUTS.'' + SCHEMA_NAME + ''.INTRA_MONTHS_WH'';
    var accountsSql = ''SELECT ACCOUNT_ID, DEPLOYMENT FROM FINOPS_OUTPUTS.'' + SCHEMA_NAME + ''.SCOPED_ACCOUNTS'';

    snowflake.execute({ sqlText:
        ''CREATE TABLE IF NOT EXISTS '' + tableName + '' ('' +
        ''    ACCOUNT_ID                   INT,''           +
        ''    DEPLOYMENT                   VARCHAR(50),''   +
        ''    DATE_DAY                     DATE,''          +
        ''    WAREHOUSE_NAME               VARCHAR(255),''  +
        ''    CREDITS                      FLOAT,''         +
        ''    NUM_EXEC_QUERIES             INT,''           +
        ''    TB_SCANNED                   FLOAT,''         +
        ''    EXECUTION_HOURS              FLOAT,''         +
        ''    ACTIVE_USERS                 INT,''           +
        ''    LIVE_DATABASES               INT,''           +
        ''    LIVE_SCHEMAS                 INT,''           +
        ''    CREDITS_PER_TB_SCANNED       FLOAT,''         +
        ''    CREDITS_PER_THOUSAND_QUERIES FLOAT,''         +
        ''    IDLE_TIME_PERCENTAGE         FLOAT,''         +
        ''    ATTRIBUTED_CREDITS           FLOAT,''         +
        ''    PCT_FROM_CACHE               FLOAT''          +
        '')''
    });

    var accounts = snowflake.execute({ sqlText: accountsSql });

    while (accounts.next()) {
        var accountId  = accounts.getColumnValue(''ACCOUNT_ID'');
        var deployment = accounts.getColumnValue(''DEPLOYMENT'');

        snowflake.execute({
            sqlText: ''CALL pst.svcs.sp_set_account_context(?, ?)'',
            binds:   [accountId, deployment]
        });

        snowflake.execute({ sqlText:
            ''INSERT INTO '' + tableName +
            '' WITH wh_metrics AS ('' +
            ''     SELECT'' +
            ''         DATE_TRUNC(\\''day\\'', start_time)                                    AS date,'' +
            ''         WAREHOUSE_NAME,'' +
            ''         COUNT(*)                                                   AS num_exec_queries,'' +
            ''         SUM(bytes_scanned) / 1024 / 1024 / 1024 / 1024            AS tb_scanned,'' +
            ''         SUM(EXECUTION_TIME) / 1000 / 3600                         AS execution_hours,'' +
            ''         COUNT(DISTINCT DATABASE_NAME || \\''.\\'' || SCHEMA_NAME)      AS live_schemas,'' +
            ''         COUNT(DISTINCT DATABASE_NAME)                              AS live_databases,'' +
            ''         COUNT(DISTINCT USER_NAME)                                  AS active_users,'' +
            ''         SUM(percentage_scanned_from_cache * EXECUTION_TIME) / SUM(EXECUTION_TIME) * 100 AS pct_from_cache'' +
            ''     FROM query_history'' +
            ''     WHERE end_time::DATE >= DATEADD(day, -45, CURRENT_DATE)'' +
            ''       AND execution_time > 0'' +
            ''       AND cluster_number IS NOT NULL'' +
            ''       AND warehouse_name NOT LIKE \\''COMPUTE_SERVICE_WH_%\\'''' +
            ''     GROUP BY ALL'' +
            '' ),'' +
            '' credits AS ('' +
            ''     SELECT'' +
            ''         DATE_TRUNC(\\''day\\'', start_time)           AS date,'' +
            ''         warehouse_name,'' +
            ''         SUM(credits_used_compute)                 AS credits,'' +
            ''         SUM(CREDITS_ATTRIBUTED_COMPUTE_QUERIES)   AS attributed_credits'' +
            ''     FROM warehouse_metering_history'' +
            ''     WHERE start_time::DATE >= DATEADD(day, -45, CURRENT_DATE)'' +
            ''     GROUP BY ALL'' +
            '' )'' +
            '' SELECT'' +
            ''     '' + accountId + ''                                         AS account_id,'' +
            ''     \\'''' + deployment + ''\\''                                    AS deployment,'' +
            ''     t1.date::DATE                                             AS date_day,'' +
            ''     t1.warehouse_name,'' +
            ''     t2.credits,'' +
            ''     num_exec_queries,'' +
            ''     tb_scanned,'' +
            ''     execution_hours,'' +
            ''     active_users,'' +
            ''     live_databases,'' +
            ''     live_schemas,'' +
            ''     DIV0(credits, tb_scanned)                                 AS credits_per_tb_scanned,'' +
            ''     DIV0(credits, (num_exec_queries / 1000))                  AS credits_per_thousand_queries,'' +
            ''     100 - (DIV0(attributed_credits, credits) * 100)           AS idle_time_percentage,'' +
            ''     t2.attributed_credits,'' +
            ''     pct_from_cache'' +
            '' FROM wh_metrics t1'' +
            '' LEFT JOIN credits t2'' +
            ''     ON  t1.date           = t2.date'' +
            ''     AND t1.warehouse_name = t2.warehouse_name''
        });
    }

    return ''Completed. Schema: '' + SCHEMA_NAME;
';
