
Should be client to interact w/ API, but is initially polluted with ETL from old yeluke.

example usage

```
honcho run python ./yelukerest_client.py --port 8080 update_meetings tmp/database-fixtures/lectures-2018.yaml
honcho run python ./yelukerest_client.py --port 8080 nukeload_quizzes tmp/database-fixtures/quizzes-2018.yaml
```

expects `YELUKEREST_CLIENT_JWT` in the environment