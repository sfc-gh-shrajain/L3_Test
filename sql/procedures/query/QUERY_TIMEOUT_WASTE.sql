CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.QUERY_TIMEOUT_WASTE("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_qtw'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_qtw(session,cust_name: str):
    try:
        # Define and set variables
        customer_name = cust_name.replace('' '', ''_'').upper()
        schema = f''FINOPS_OUTPUTS.{customer_name}''

        # Set table variables
        query_timeout_waste = f''{schema}.QUERY_TIMEOUT_WASTE''
        query_history = f''{schema}.QUERY_HISTORY_30D''

        # Insert data into identifier table
        INSERT_QUERY = f"""
INSERT INTO {query_timeout_waste}
WITH BaseTable AS (
        SELECT account_id
        ,deployment
        ,WAREHOUSE_NAME
        ,WAREHOUSE_SIZE 
        ,EXECUTING_SEC
        ,decode (WAREHOUSE_SERVER_SIZE::int
                    , 1,14400
                    , 2,14400
                    , 4,14400
                    , 8,14400
                    , 16,14400
                    , 32,14400
                    , 64,14400
                    , 128,14400
                    , 20,14400
                    , 40,14400
                    , 256, 14400
                    , 512, 14400
                    , null
                ) as Warehouse_Timeout_Max
        , CASE WHEN EXECUTING_SEC > Warehouse_Timeout_Max THEN EXECUTING_SEC-Warehouse_Timeout_Max ELSE 0 END AS Wasted_Seconds
        , Wasted_Seconds * (WAREHOUSE_SERVER_SIZE/3600) as Wasted_Seconds_Max_Credits
        , CASE WHEN EXECUTING_SEC > Warehouse_Timeout_Max THEN Warehouse_Timeout_Max ELSE EXECUTING_SEC END AS Total_Seconds_with_timeout_cut
        , Total_Seconds_with_timeout_cut * (WAREHOUSE_SERVER_SIZE/3600) as Total_Seconds_with_timeout_cut_Max_Credits
        , CASE WHEN EXECUTING_SEC > Warehouse_Timeout_Max THEN 0 ELSE EXECUTING_SEC END AS Total_Seconds_Without_Bad_Queries
        , Total_Seconds_Without_Bad_Queries * (WAREHOUSE_SERVER_SIZE/3600) as Total_Seconds_Without_Bad_Queries_Max_Credits
        , EXECUTING_SEC * (WAREHOUSE_SERVER_SIZE/3600) as Max_WH_Credits
        FROM {query_history}
        )

        SELECT account_id
        ,deployment
        ,WAREHOUSE_NAME
        //,WAREHOUSE_SIZE
        ,DIV0((Max_WH_Credits - Total_Seconds_with_timeout_cut_Max_Credits),Max_WH_Credits) * 100 as LowerBoundCreditsSaved_Percentage
        ,DIV0((Max_WH_Credits - Total_Seconds_Without_Bad_Queries_Max_Credits),Max_WH_Credits) * 100 as UpperBoundCreditsSaved_Percentage
        ,Total_Seconds
        ,Max_WH_Credits
        ,Wasted_Seconds_Max_Credits
        ,Total_Seconds_with_timeout_cut_Max_Credits
        FROM (
        //,(Total_Seconds - Total_Seconds_with_timeout_cut)/Total_Seconds as Total_Seconds_with_timeout_cut_PercentofTotal
        SELECT account_id
        ,deployment
        ,WAREHOUSE_NAME
        //,WAREHOUSE_SIZE
        ,SUM(EXECUTING_SEC) as Total_Seconds
        ,SUM(Max_WH_Credits) as Max_WH_Credits
        ,SUM(Wasted_Seconds) AS Wasted_Seconds
        ,SUM(Wasted_Seconds_Max_Credits) as Wasted_Seconds_Max_Credits
        ,SUM(Total_Seconds_with_timeout_cut) as Total_Seconds_with_timeout_cut
        ,SUM(Total_Seconds_with_timeout_cut_Max_Credits) as Total_Seconds_with_timeout_cut_Max_Credits
        ,SUM(Total_Seconds_Without_Bad_Queries) as Total_Seconds_Without_Bad_Queries
        ,SUM(Total_Seconds_Without_Bad_Queries_Max_Credits) as Total_Seconds_Without_Bad_Queries_Max_Credits
        FROM BASETABLE
        GROUP BY ALL)
    
        ;
        """

        # Execute the insert query
        session.sql(INSERT_QUERY).collect()

        return ''Data inserted successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
