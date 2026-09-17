def search(cur, city):
    # DB-API parameter substitution. Must NOT be flagged.
    cur.execute("SELECT * FROM customers WHERE city = %s", (city,))
    return cur.fetchall()
