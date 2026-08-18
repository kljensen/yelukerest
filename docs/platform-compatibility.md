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
    "schema_compatibility_version": 6,
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
    "schema_compatibility_versions": {6},
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

An **additive** shape change is still a shape change, and it is still not a
floor. Version 5 only adds `api.assignment_repositories`, so a client that never
reads it works against 4 and 5 alike and declares `{4, 5}`. A client that needs
it declares `{5}` alone -- and specifically not `>= 5`, because the next shape
that subtracts something would sail through that floor exactly the way `>= 3`
sailed through version 4. Version 6 is additive in the same way, so that client
extends its set to `{5, 6}` once it has confirmed it reads nothing that changed.

Raise the relevant version in the same migration that introduces the new
contract, by replacing `api.platform_version` there -- the values live in the
migration that last set them, not in `db/src/`, which is the frozen bootstrap
input. If the change **removes** anything from the `api` schema, it is a
`schema_compatibility_version` bump, because no `admin_api_version` bump can
warn a client about something that disappeared.

Do not pin the shape you just minted in that migration's `verify.sql`.
`zapadka verify` re-runs every applied migration's script against head, so an
equality there is a veto on every later shape change; set membership is the
operator a *client* uses to declare what it supports, not an assertion a
migration can make about the database in front of it.

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
- `schema_compatibility_version` **5** added `api.assignment_repositories`: the
  record of which forge repository belongs to which student or team for which
  assignment, needed because GitHub Classroom shuts down on 2026-08-28 and
  course repos must provision student repositories themselves. It removes
  nothing, so a client that does not read it declares `{4, 5}`; a client that
  provisions repositories declares `{5}`. No RPC came with it, which is why
  `admin_api_version` stayed at 9. See
  [Admin API](admin-api.md#assignment-repositories).
- `schema_compatibility_version` **6** added `api.assignment_repository_snapshots`
  and `api.assignment_repository_snapshots_due`: the record of what the graded
  artifact actually was at each student's effective deadline, and the queue of
  repositories that have become due for a capture. It removes nothing, so a
  client that reads neither declares `{4, 5, 6}`; the snapshot runner declares
  `{6}`. No RPC came with it -- the runner reads one view and writes another,
  and PostgREST's ordinary filtering is enough -- which is why
  `admin_api_version` stayed at 9. See
  [Admin API](admin-api.md#repository-snapshots).
- `admin_api_version` **8** added `api.grant_assignment_extension`. Assignments
  are the only thing with an extendable deadline.
- `admin_api_version` **9** added `api.upsert_user_secrets` and
  `api.upsert_team_secrets`. Two RPCs rather than one with a nullable target,
  because the two uniqueness rules are two different partial indexes and a
  single entry point would pick one of them from which field happened to be
  null. See [Admin API](admin-api.md#secret-distribution).
