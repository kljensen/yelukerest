# A restful API for class data
Using the [postgrest start kit](https://github.com/subzerocloud/postgrest-starter-kit)

## Notes

Table dump as inserts (useful for making tests)
```
pg_dump -h localhost -p 5432 -U $SUPER_USER --table data.meeting --data-only --column-inserts -W app -n api
```

Where `$SUPER_USER` is in your environment and is the superuser for the Postgres instance.