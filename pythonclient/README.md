
# Yelukerest Python Clients

This directory has two intentionally separate clients.

## HTTP API client

`api_client.py` talks to the PostgREST `api` schema and should be the default
path for supported admin imports.

Required environment:

- `YELUKEREST_CLIENT_JWT`: a faculty user JWT.
- `YELUKEREST_BASE_URL`: deployment base URL, without `/rest`. Defaults to
  `https://localhost`.

Examples:

```sh
uv run --python python3.12 --no-managed-python python api_client.py \
  --base-url https://course.example.edu \
  sync-meetings fixtures/meetings.yaml 858
```

```sh
uv run --python python3.12 --no-managed-python python api_client.py \
  --base-url https://course.example.edu \
  sync-assignments 858 fixtures/assignments/grading/*/assignment.yaml --delete
```

Assignment YAML may keep the historical `child:assignment_fields` key. The API
client converts it to the normalized `fields` array expected by
`api.sync_assignments`.

Supported API operations:

- `platform-version`: calls `GET /rest/platform_version` and does not require a
  JWT.
- `sync-meetings`: calls `POST /rest/rpc/sync_meetings`.
- `sync-assignments`: calls `POST /rest/rpc/sync_assignments`.

## Legacy direct-DB client

`db_client.py` connects with `DATABASE_URL` and writes directly to `data.*`.
Keep it only for workflows that have not moved behind API RPCs yet:

- roster/user import and LDAP enrichment;
- registration API import;
- quiz metadata upsert.

The old `update-meetings` and `update-assignments` commands still exist for
incremental course-admin migration, but they print warnings because the API
client now covers those operations.
