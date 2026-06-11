# Import python packages
import streamlit as st
from snowflake.snowpark.context import get_active_session
import numpy as np
import pandas as pd
from snowflake.connector.pandas_tools import write_pandas



if 'current_stage' not in st.session_state:
    st.session_state.current_stage = 0

def set_current_stage(current_stage):
    st.session_state.current_stage = current_stage 

def get_df(query):
    session = get_active_session()
    df = session.sql(query)
    return df




#create temporary tables for the client and
@st.cache_resource
def create_ult_sfdc_act_table(schema_name, ult_parent):
    table_name = 'FINOPS_OUTPUTS.'+ schema_name + '.SFDC_ACCOUNTS'
    ult_table_name = 'FINOPS_OUTPUTS.' + schema_name + '.ULT_SFDC_ACCOUNTS'
    schema = 'FINOPS_OUTPUTS.' + schema_name

    #set the time zone
    #session.
    #query = 'alter session set timezone = \'UTC\''
    #get_df(query).collect()
    
    st.write("1")
    query = 'CREATE OR REPLACE TRANSIENT SCHEMA '+ schema +' CLONE FINOPS.L3_TEMPLATE WITH MANAGED ACCESS'
    get_df(query).collect() #break 1
    
    st.write("2")
    try:
        query = '''CREATE OR REPLACE TABLE '''+ schema + '''.ULT_SFDC_ACCOUNTS AS 
    SELECT 
        acct.id as salesforce_account_id,
        acct.name as salesforce_account_name,
        acct.ULTIMATE_PARENT_CASE_SAFE_ID_TEXT_C as ultimate_parent_salesforce_account_id,
        ult.name as ultimate_parent_salesforce_account_name
    from snowhouse.sales.account acct
    left join snowhouse.sales.account ult
    on acct.ULTIMATE_PARENT_CASE_SAFE_ID_TEXT_C = ult.id
    WHERE ult.name = \'''' + ult_parent +'''\' AND acct.capacity_counter_c >0;
    
    '''
        get_df(query).collect() #break 2
    except:
        ult_parent = ult_parent.replace("'", "''")

        query = '''CREATE OR REPLACE TABLE '''+ schema + '''.ULT_SFDC_ACCOUNTS AS
        SELECT
            acct.id as salesforce_account_id,
            acct.name as salesforce_account_name,
            acct.ULTIMATE_PARENT_CASE_SAFE_ID_TEXT_C as ultimate_parent_salesforce_account_id,
            ult.name as ultimate_parent_salesforce_account_name
        from snowhouse.sales.account acct
        left join snowhouse.sales.account ult
        on acct.ULTIMATE_PARENT_CASE_SAFE_ID_TEXT_C = ult.id
        WHERE ult.name = \'''' + ult_parent +'''\' AND acct.capacity_counter_c >0;
        '''

        get_df(query).collect() # This will now use the escaped string
    st.write("3")
    query = '''CREATE OR REPLACE TABLE ''' + schema + '''.sfdc_accounts AS 
select 
        map.salesforce_account_id
        ,map.salesforce_account_name
        ,map.snowflake_account_id
        ,map.snowflake_deployment
        ,map.snowflake_account_name
        ,a.service_level
    from finance.customer.salesforce_snowflake_mapping map
    join ''' + ult_table_name + ''' u on u.salesforce_account_id = map.salesforce_account_id
    join snowhouse_import.prod.ACCOUNT_EXTENDED_PROPERTIES_ETL_V a on map.snowflake_account_id = a.account_id and map.snowflake_deployment = a.deployment
    group by ALL
    ;'''
    st.write("4")
    get_df(query).collect()#break 3

    revenue = populate_other_tables(schema_name)
    st.write("5")
    return revenue
    
def populate_other_tables(schema_name):
    schema = 'FINOPS_OUTPUTS.' + schema_name
    st.write("6")
    session = get_active_session()
    
    # Current quarter start date
    current_quarter_start_date = session.sql(f"SELECT date_trunc('quarter', current_date())").collect()[0][0]
    current_quarter_start_date = current_quarter_start_date.strftime('%Y-%m-%d')
    st.write("7")
    # Two years prior end quarter date
    prior_two_years_end_quarter_date = session.sql(f"SELECT dateadd(day, -1, '{current_quarter_start_date}'::DATE)").collect()[0][0]
    prior_two_years_end_quarter_date = prior_two_years_end_quarter_date.strftime('%Y-%m-%d')
    st.write("8")
    # Two years prior beginning date
    prior_two_years_beginning_date = session.sql(f"SELECT dateadd(year, -2, dateadd(month, -3, '{current_quarter_start_date}'::DATE))").collect()[0][0]
    prior_two_years_beginning_date = prior_two_years_beginning_date.strftime('%Y-%m-%d')
    st.write("9")
    prior_month_end_date = session.sql(f"SELECT DATEADD('day',-1,DATE_TRUNC('month',CURRENT_DATE()))").collect()[0][0]
    prior_month_end_date = prior_month_end_date.strftime('%Y-%m-%d')
    st.write("10")
    prior_month_start_date = session.sql(f"(SELECT DATEADD('month',-1,date_trunc('month', current_date)));").collect()[0][0]
    prior_month_start_date = prior_month_start_date.strftime('%Y-%m-%d')
    st.write("11")
    table_name = schema + '.BILLING'
    sfdc_table = schema + '.SFDC_ACCOUNTS'
#alter session set timezone = 'UTC';
    st.write("12")
    query = '''//Billing Table
CREATE OR REPLACE TABLE ''' + table_name + ''' AS (
    SELECT
            YEAR(map.general_date::DATE) || '-Q'  || QUARTER(map.general_date::DATE) AS PERIOD,
            DATE_TRUNC('month', map.general_date::DATE) as MONTH,
            map.SALESFORCE_ACCOUNT_ID as SF_ID,
            map.SALESFORCE_ACCOUNT_NAME as SF_NAME,
            map.snowflake_account_id::INT as ACCOUNT_ID,
            map.snowflake_account_name as NAME,
            SNOWFLAKE_ACCOUNT_ALIAS as ALIAS,
            map.snowflake_deployment as DEPLOYMENT,
            map.CLOUD,
            map.CLOUD_PROVIDER_REGION,
            map.SERVICE_LEVEL,
            map.METERED_CURRENCY,
            map.CONTRACT_CURRENCY,
            map.revenue_category,
            CASE
                WHEN revenue_category IN ('Storage','Reader Storage') THEN 'Storage'
                WHEN revenue_category IN ('Reader Compute','Compute') THEN 'Compute'
                ELSE 'Other'
            END AS revenue_group,
            SUM(round(revenue,2)) as REVENUE,
            SUM(round(REVENUE_LOCAL,2)) as REVENUE_LOCAL,
            SUM(WAREHOUSE_CREDITS) as CREDITS,
            SUM(DAILY_STORAGE_TB + READER_STORAGE_TB) as STORAGE_TB,
            SUM(DATA_TRANSFER_TB + READER_DATA_TRANSFER_TB) as TRANSFER_TB,
            DIV0(SUM(sub.price_per_credit*WAREHOUSE_CREDITS),NULLIF(SUM(WAREHOUSE_CREDITS),0)) as price_per_credit,
            DIV0(SUM(sub.overage_price_per_credit*WAREHOUSE_CREDITS),NULLIF(SUM(WAREHOUSE_CREDITS),0)) as credit_list_price,
            DIV0(SUM(sub.storage_pricing*(daily_storage_tb+READER_STORAGE_TB)),NULLIF(SUM(daily_storage_tb+READER_STORAGE_TB),0)) as storage_pricing,
            DIV0(SUM(sub.overage_storage_pricing*(daily_storage_tb+READER_STORAGE_TB)),NULLIF(SUM(daily_storage_tb+READER_STORAGE_TB),0)) as storage_list_price,
            DIV0(SUM(sub.capacity_discount * revenue),SUM(revenue)) as discount
    from finance.customer.SNOWFLAKE_ACCOUNT_REVENUE_LONG map
    join ''' + sfdc_table + ''' sa 
        on map.snowflake_account_id = sa.snowflake_account_id
        and map.snowflake_deployment = sa.snowflake_deployment
    LEFT JOIN FINANCE.CUSTOMER.PRICING_DAILY sub on 
    map.snowflake_account_id = sub.snowflake_account_id 
    and map.snowflake_deployment = sub.snowflake_deployment
    and map.general_date::DATE = sub.general_date
    WHERE 1 = 1 
    and map.general_date BETWEEN \'''' + prior_two_years_beginning_date + '''\' and \'''' + prior_month_end_date + '''\'
    and coalesce(revenue,0) <> 0
    GROUP BY ALL
    ORDER BY "MONTH" ASC
    );
'''
    st.write("13")
    get_df(query).collect() #break 14

#    query = ''' //Need to have the ability to update this table manually (streamlit) because it can be off by up to 50 cents due to billing timing in the base tables.
#CREATE OR REPLACE TABLE '''+ schema + '''.COST_TABLE AS (
#SELECT
#ACCOUNT_ID AS ACCOUNT_ID
#,DEPLOYMENT
#,ROUND(AVG((CASE WHEN revenue_category = 'Storage' and revenue_group = 'Storage' THEN REVENUE/STORAGE_TB ELSE NULL END)),2) as STORAGE_COST
#,ROUND(AVG((CASE WHEN revenue_category = 'Compute' and revenue_group = 'Compute' THEN REVENUE/CREDITS ELSE NULL END)),2) as CREDIT_COST
#FROM '''+ schema + '''.BILLING
#WHERE MONTH = \''''+ prior_month_start_date + '''\'
#GROUP BY ALL
#)'''
#    get_df(query).collect() #break 6

    
    query = '''
SELECT 
SF_ID
,SF_NAME
,ACCOUNT_ID
,NAME as LOCATOR
,ALIAS as ACCOUNT_NAME
,DEPLOYMENT
,SUM(REVENUE) as TOTAL_REVENUE
,SUM(CASE WHEN MONTH >= DATEADD('month',-3,DATE_TRUNC('month',CURRENT_DATE)) THEN REVENUE ELSE 0 END) as LAST_3_MONTH_REVENUE
FROM ''' + schema + '''.BILLING
GROUP BY ALL
;'''

    revenue = get_df(query).to_pandas() #break 7
    
    return revenue

#first selection form for the human readable customer name and the SDFC Ultimate Parent Name Dropdown
with st.form("Customer Lookup"):
    #query customers for a list of names to populate the select box

    #replace with human readable names, match human readable to this on the backend
    query = '''SELECT DISTINCT
    ult.name as ultimate_parent_salesforce_account_name
from snowhouse.sales.account acct
left join snowhouse.sales.account ult
on acct.ULTIMATE_PARENT_CASE_SAFE_ID_TEXT_C = ult.id
WHERE true
AND acct.capacity_counter_c >0'''
    
    name_df = get_df(query).to_pandas()
    name_df = name_df.sort_values(by='ULTIMATE_PARENT_SALESFORCE_ACCOUNT_NAME')
    customer_names = st.selectbox("Ultimate Parent Name",name_df.ULTIMATE_PARENT_SALESFORCE_ACCOUNT_NAME, index = None) 

    schema_customer_name = st.text_input("insert customer name")
    schema_customer_name = schema_customer_name.replace(" ", "_")
    schema_customer_name = schema_customer_name.upper()
    customer_lookup = st.form_submit_button("Perform Account Lookup")


    
    #check if the first two boxes are entered correctly
    if customer_lookup:
        customer_table = False
        #query customer table
        if schema_customer_name == "":
            st.error("please insert customer name")
            st.stop
        if customer_names == None:
            st.error("please select an SDFC Ultimate Parent Name")
            st.stop
        if ((customer_names != None) & (schema_customer_name != "")):
            set_current_stage(1)
    


#if the first portion is populated
if st.session_state.current_stage >= 1:
    with st.form("Account Selection"):

        #Create customer table, sorted by 3 month revenue for account select
        customer_lookup_df = create_ult_sfdc_act_table(schema_customer_name, customer_names)
        customer_lookup_df = customer_lookup_df.sort_values(by = 'LAST_3_MONTH_REVENUE', ascending = False)
        customer_lookup_df.insert(0, "Select Account", [0]*customer_lookup_df.index)

        #display the customer table with checkboxes per account
        customer_short_data = st.data_editor(customer_lookup_df, column_config={"Select Account": st.column_config.CheckboxColumn("Select Account")}, hide_index = True)
        
        #populate a DataFrame to use for script select
        script_names_df = pd.DataFrame(["Warehouse Analysis", "Query Analysis", "Storage Analysis", "Other (Serverless + Copy)", "ROI", "Usage Context"], columns = ["Script Name"])
        script_names_df.insert(0, "Run", [0]*6)
        #display the script select
        analysis_select = st.data_editor(script_names_df, column_config={"Run": st.column_config.CheckboxColumn("Run")}, hide_index = True)

        #kick off analyses button
        script_kick_off = st.form_submit_button("Run chosen scripts on chosen accounts")
        
        if script_kick_off:
            st.write("Analyses may take up to two hours per selected account to complete")
            out_df = customer_short_data[customer_short_data['Select Account'] == 1]
            out_df = out_df.reset_index()
            for i in script_names_df['Script Name']:
                value = analysis_select[analysis_select['Script Name'] == i].Run.values[0]
                value = pd.Series(value for x in out_df.index)
                out_df.insert(len(out_df.columns), i, value)
            out_df = out_df.drop(["Select Account", "TOTAL_REVENUE", "LAST_3_MONTH_REVENUE", "index"], axis = 1)
            out_df.columns=["SF_ID", "SF_NAME", "ACCOUNT_ID", "LOCATOR", "ACCOUNT_NAME", "DEPLOYMENT", "WAREHOUSE_ANALYSIS", "QUERY_ANALYSIS", "STORAGE_ANALYSIS", "OTHER_ANALYSIS", "ROI_ANALYSIS", "USAGE_CONTEXT_ANALYSIS"]
            session = get_active_session()
            final = session.write_pandas(df = out_df, table_name = 'SCOPED_ACCOUNTS', schema = schema_customer_name.upper(), auto_create_table = True, database= 'FINOPS_OUTPUTS',overwrite=True)
            st.write("scoped accounts table created. Analysis has begun.")
            #st.write("analyses have started, it may take up to two hours per selected account for these analyses to run")
            task = 'CREATE OR REPLACE TASK FINOPS_OUTPUTS.' + schema_customer_name + '.ACCOUNT_REFRESH WAREHOUSE = FINOPS_WH SCHEDULE = \'' + '60 MINUTES' + '\' AS call FINOPS_OUTPUTS.' + schema_customer_name + '.account_orchestrator(\'' + schema_customer_name + '\');'
            session.sql(task).collect()
            run_task = 'EXECUTE TASK FINOPS_OUTPUTS.' + schema_customer_name + '.ACCOUNT_REFRESH;'
            session.sql(run_task).collect()
            st.write('analysis started; check for scoped accounts views in schema for when it is finished.')