# Platform Compatibility

Course admin tooling should fail fast when it targets a Yelukerest deployment
with an incompatible schema or admin API. Yelukerest exposes a stable,
unauthenticated, read-only endpoint for that preflight:

```sh
curl -fsS https://example.edu/rest/platform_version
```

The response is a one-row JSON array:

```json
[
  {
    "platform": "yelukerest",
    "platform_compatibility_version": 1,
    "schema_compatibility_version": 4,
    "admin_api_version": 9
  }
]
```

Clients should compare these as integers, not strings -- but not all with the
same operator. `admin_api_version` takes a floor (`>=`); the schema shape takes
set membership. The section below explains why, and getting it wrong produces a
preflight that certifies the very incompatibility it exists to catch. A course
admin repo declares what it supports and rejects everything else:

```python
import json
import urllib.request

required = {
    "platform": "yelukerest",
    # A set, not a floor -- see below.
    "schema_compatibility_versions": {4},
    "admin_api_version": 9,
}

with urllib.request.urlopen("https://example.edu/rest/platform_version") as res:
    actual = json.load(res)[0]

assert actual["platform"] == required["platform"]
assert actual["schema_compatibility_version"] in required["schema_compatibility_versions"]
assert actual["admin_api_version"] >= required["admin_api_version"]
```

## The two versions are checked differently, on purpose

`admin_api_version` only ever grows. Each bump adds an RPC without removing
one, so "at least N" is exactly right: a deployment at 10 can serve every client
written against 9.

`schema_compatibility_version` names a schema **shape**, and a shape can lose
things. Version 4 removed `api.quiz_grade_exceptions`, `api.quizzes.duration`,
and `api.quizzes.is_offline`. A client pinned to `>= 3` would sail through its
own preflight against a version 4 deployment and then take a PostgREST 400 on
its first request -- the preflight would have certified the exact incompatibility
it exists to catch.

So check `schema_compatibility_version` for **membership in the set of shapes
your client actually supports**. A client that has been updated for the removals
declares `{4}`; one that works against both declares `{3, 4}`. A floor is only
safe for a version that never subtracts.

Update the values in `db/src/api/yeluke/platform_version.sql` when a change
requires course admin tools to know about a new platform behavior, schema
shape, or admin API contract. Raise the relevant version in the same change that
introduces the new contract -- and if the change **removes** anything from the
`api` schema, it is a `schema_compatibility_version` bump, because no
`admin_api_version` bump can warn a client about something that disappeared.

## What the current versions mean

- `schema_compatibility_version` **4** removed the online-quiz remnants:
  `api.quiz_grade_exceptions` and its `data.quiz_grade_exception` table are
  gone, and `api.quizzes` no longer carries `duration` or `is_offline`. A
  client that selects any of those against a version 4 deployment gets an
  error, so add `4` to your supported set only once you have stopped reading
  them. Removing those reads does not cost you version 3 -- nothing there
  requires them -- so such a client declares `{3, 4}` and works against both. A
  client that still reads them declares `{3}`. Quizzes are paper-only; see
  [Admin API](admin-api.md#there-is-no-quiz-extension).
- `admin_api_version` **8** added `api.grant_assignment_extension`. Assignments
  are the only thing with an extendable deadline.
- `admin_api_version` **9** added `api.upsert_user_secrets` and
  `api.upsert_team_secrets`. Two RPCs rather than one with a nullable target,
  because the two uniqueness rules are two different partial indexes and a
  single entry point would pick one of them from which field happened to be
  null. See [Admin API](admin-api.md#secret-distribution).
