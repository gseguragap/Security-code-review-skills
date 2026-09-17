public class CustomerRepo {
    public List<Customer> Search(string city) {
        // Parameterized: EF Core binds `city` as a DbParameter. Must NOT be flagged.
        return _db.Customers.FromSqlInterpolated($"SELECT * FROM Customers WHERE City = {city}").ToList();
    }
    public List<Customer> All() => _db.Customers.Where(c => c.Active).ToList();
}
