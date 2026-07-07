# Database Tests

Run these from the repository root with the development stack running:

```sh
bun run test_db
```

The command resets sample data with `bin/reset_db.sh`, then runs all
`tests/db/*.sql` files with local `pg_prove`.

Requirements:

- `psql`
- `pg_prove` from pgTAP
- a running development database reachable with the values in `.env`

If the host database port differs from `.env`, override it for the test run:

```sh
DB_TEST_PORT=55432 bun run test_db
```
