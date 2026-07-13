CREATE OR REPLACE PROCEDURE FINOPS.L3_TEMPLATE.COST_TABLE("CUST_NAME" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'insert_data_into_ct'
EXECUTE AS OWNER
AS '
from snowflake.snowpark import functions as F
from snowflake.snowpark.functions import col
import logging

logger = logging.getLogger("python_logger")

def insert_data_into_ct(session,cust_name: str):
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
        scoped_table = f''{schema}.SCOPED_ACCOUNTS''
        ct_table = f''{schema}.COST_TABLE'';

        # Insert data into identifier table
        INSERT_QUERY = f"""
       INSERT INTO {ct_table}
            SELECT salesforce_account_id
            ,salesforce_account_name
            ,snowflake_account_id::INT as account_id
            ,snowflake_deployment as deployment
            ,MIN(storage_pricing) as storage_pricing_min
            ,MAX(storage_pricing) as storage_pricing_max
            ,MIN(PRICE_PER_CREDIT) as price_per_credit_min
            ,MAX(price_per_credit) as price_per_credit_max
            ,ROUND(AVG(storage_pricing),2) as storage_price
            ,ROUND(AVG(price_per_credit),2) as price_per_credit
            FROM FINANCE.CUSTOMER.PRICING_DAILY pd
            JOIN {scoped_table} s on 
                pd.snowflake_account_id = s.account_id
                and pd.snowflake_deployment = s.deployment
            WHERE date_trunc(''month'',general_date) = ''{previous_month_start}''
            GROUP BY ALL
            
        """

        # Execute the CTAS query
        session.sql(INSERT_QUERY).collect()

        return ''Table Created successfully''
    
    except Exception as err:
        return f''Error: {str(err)}''  # Return error message if any
';
