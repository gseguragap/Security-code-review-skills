def search(cur, city):
    cur.execute(f"SELECT * FROM customers WHERE city = '{city}'")
    return cur.fetchall()
