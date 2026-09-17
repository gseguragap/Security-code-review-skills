public class CustomerRepo {
    public List<Customer> Search(string city) {
        var sql = "SELECT * FROM Customers WHERE City = '" + city + "'";
        return _db.Customers.FromSqlRaw(sql).ToList();
    }
}
