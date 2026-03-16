import snowflake.connector


def set_connection(role_name, warehouse_name):
    conn = snowflake.connector.connect(
                    user='jozhang',
                    account='snowhouse',
                    authenticator = 'externalbrowser'

                    )
    cs = conn.cursor()
    print("use ROLE " + role_name + " ")
    print("use warehouse " + warehouse_name + " ")
    print("alter session set timezone = 'UTC'")

    cs.execute("use ROLE " + role_name + " ")
    cs.execute("use SECONDARY ROLE "  + "ALL")
    cs.execute("use warehouse " + warehouse_name + " ")
    cs.execute("alter session set timezone = 'UTC'")

    return cs

def close_connection(cursor):
    cursor.close()
