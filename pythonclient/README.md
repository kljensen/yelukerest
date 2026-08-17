
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

- `platform-version`: calls `GET /rest/platform_version`. Sends **no** credential
  even when one is configured — PostgREST validates any token it is handed, and
  this is the preflight you run to diagnose a broken token.
- `sync-meetings`: calls `POST /rest/rpc/sync_meetings`.
- `sync-assignments`: calls `POST /rest/rpc/sync_assignments`.
- `roster`: students for the course.
- `find-user FIELD VALUE`: exact match on `netid`, `email`, or `nickname`. The
  caller says which field it means; this is deliberately not a fuzzy resolver.
- `search-users TERM`: substring search, kept separate from exact resolution.
- `export-submissions`: submitted work, one row per submitted field. A team
  submission appears once rather than once per member — see `docs/admin-api.md`
  for why, and for what the export deliberately does not answer.

Reads other than `platform-version` require a faculty JWT. See
[ADR 0002](../docs/adr/0002-admin-api-authentication.md) for how to get one, and
why a standing faculty token in a synced `.env` is rejected.

`api.import_assignment_grades` exists on the platform as of `admin_api_version` 6,
but has **no client subcommand yet** — call it over `POST /rest/rpc/` directly for
now. Its payload carries final absolute points; curving stays with the caller.

## Legacy direct-DB client

`db_client.py` connects with `DATABASE_URL` and writes directly to `data.*`.
Keep it only for workflows that have not moved behind API RPCs yet:

- roster/user import and LDAP enrichment;
- registration API import;
- quiz metadata upsert.

The old `update-meetings` and `update-assignments` commands still exist for
incremental course-admin migration, but they print warnings because the API
client now covers those operations.
