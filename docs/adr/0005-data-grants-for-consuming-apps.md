# ADR 0005: Apps That Consume Course Data Get A Grant, Not A Person's Credential

## Status

Accepted, 2026-09-16. Plan reviewed with codex over two rounds; the
implementation over three. Deployed to production the same day. Records the
decision behind milestone "Roadmap 20: Data Grants For Consuming Apps"
(issues #384–#388).

## Context

The tacky-website voting app needs one thing from the course platform: every
student's submitted URL for one assignment, with the submitter's netid and
name. It does not need anything else a faculty member can see, and it should
not have it. The same shape recurs: an app that lists who submitted assignment
foo, a leaderboard that shows nicknames for one exam. Each wants a key that can
read exactly what it was given, that faculty can hand out and take back without
a deploy, and that leaves a record of what it could see.

Nothing in the platform expresses that today. Every credential is a person.
A faculty API token reads whatever faculty reads. Its scopes look like they
narrow that, but they do not: the pre-request hook `api.check_request_jwt()`
(`migrations/01a0481a-2f22-7a50-a6a1-3886f410d86b-bound-student-row-writes/deploy.sql`)
checks only `submissions:write`, and only on writes. Personal tokens also go
through an exchange step in authapp (`authapp/apitoken.go`) before PostgREST
sees them, so there is no place to bolt a narrower read onto them.

One detail shapes the schema. An assignment field is identified by
`(slug, assignment_slug)` (`db/src/data/yeluke/assignment_field.sql`), and the
slug `url` recurs across assignments. A grant that named assignments in one
list and fields in another would quietly grant `url` on every assignment in
the first list.

## Decision

**The key is a grant, not an identity.** A grant is a stored permission: which
assignments, which identity attributes, which fields. Faculty create it through
the API. The credential is a JSON Web Token (JWT) the platform signs that names
the grant; the permission itself stays in the database, so revoking the row
stops the token. There is no wildcard for "every assignment". That is a
faculty token, and if you want one, use one.

**Permissions live in three tables, and they are immutable once created.**
`data.api_grant` holds the name, who created it and when, when it expires, and
who revoked it and when. `data.api_grant_assignment` holds one row per granted
assignment with the identity attributes the consumer may see, any subset of
`netid`, `name`, `nickname`, `team_nickname`, possibly none.
`data.api_grant_assignment_field` holds one row per granted field, with a
foreign key to the real assignment field, so a field cannot be renamed or
deleted while a grant references it. Expiry is capped at 180 days after
creation, the same cap user tokens carry. After creation nothing changes:
permissions accept no insert, update, or delete, and a grant can be revoked
once, keeping the first actor and time. To change a grant, revoke it and
create another.

**The reader returns complete submissions and granted values only.** A
submission appears only if every granted field has a non-empty body; one that
has not filled in the granted field is left out, not shown with blanks. For an
individual assignment the identity comes from the submission's own user; for
a team assignment it is the team nickname, and the person-level attributes are
null. The reader never substitutes whoever last edited a field, or one member
of a team, for the submitter. Keys that were granted but are null stay in the
output as null; keys that were not granted are absent.

**One function is the whole API surface.**

```sql
api.granted_submissions(
  p_assignment_slug text DEFAULT NULL,
  p_after_id int DEFAULT NULL,
  p_limit int DEFAULT 200
) RETURNS SETOF jsonb
```

Each row is `{assignment_slug, submission_id, is_team, created_at, updated_at,
identity: {...}, fields: {slug: {body, updated_at}}}`. Rows come in submission
id order, and `p_after_id` pages through them; the limit defaults to 200 and
is capped at 500. Asking for a slug the grant does not cover returns an empty
array, after the credential and the grant row have been checked, so the reply
says nothing about assignments the caller cannot see.

**Consumers refresh the whole set; there is no incremental poll.** A poll
"since a timestamp" was considered and rejected. Editing a field updates the
child row's timestamp but not the parent submission's
(`db/src/data/yeluke/assignment_field_submission.sql`), and clearing a field
deletes the child row and leaves no marker. A timestamp cursor would miss both.
A consumer walks every page each cycle and replaces its local copy only after a
full successful pass. At course scale that is one request.

**Faculty issue, list, and revoke.** `api.create_api_grant(p_name,
p_assignments jsonb, p_expires_at)` validates the request, inserts the rows,
signs the token, and returns it once; it is never stored. Signing reuses the
`pgjwt.sign(..., settings.get('jwt_secret'))` path that `auth.sign_jwt()` uses
(`db/src/libs/auth/schema.sql`). Claims are `role: grant_consumer`,
`sub: grant:<id>`, `grant_id`, `iss`, `aud`, `exp`, `iat`, `nbf`, and a random
`jti`. `api.revoke_api_grant(id)` revokes, and `api.api_grants` lists grants
with their permissions and lifecycle, never their credentials.

## Consequences

Easier: giving an app precisely the data it needs is a faculty API call, and
taking it away is another. What each app could see is on record. The first
consumer, the voting app, no longer holds a faculty token.

Harder: a consumer re-reads the whole set rather than the delta, and the pages
of one pass are not a single database snapshot. A referenced assignment field
cannot be renamed or deleted, even after the grant is revoked, until a
migration policy for that exists. Changing what an app may see means a new
credential.

Deliberately not done: count-only responses, filtering to particular students
or teams, opaque keys exchanged the way personal tokens are, writes of any
kind, and an incremental change feed. Each is a separate decision if the need
appears.

The work lands as three migrations, schema, credential boundary, reader, so
each can be reviewed on its own, with the tests arriving alongside and
finishing before the faculty-facing controls.

## PostgREST mechanics

For a reader who knows PostgREST, this is how a consumer's request runs.

PostgREST verifies the JWT against the shared secret and switches from the
authenticator to the role in the token, `grant_consumer`. That role is
`NOLOGIN`, granted to the authenticator so the switch is allowed, and a member
of nothing else. Its privileges are `USAGE` on the `api` schema and `EXECUTE` on
exactly two functions: the reader and the pre-request hook. It can select from
no table or view. Because PostgREST exposes only what the role may touch, every
URL but `/rpc/granted_submissions` fails on privileges before any policy runs.

The pre-request hook then runs. For this role it allows only `GET` and `HEAD`,
only on that path, read from the transaction settings `request.method` and
`request.path`, and it refuses if either is missing. It requires the exact
role, a positive integer `grant_id`, a `sub` equal to `grant:` followed by that
id, the expected issuer and audience, and a numeric `exp`. A missing or
malformed claim fails closed. The existing audience check is `IF NOT (...)`,
which lets a missing audience through as SQL NULL; it becomes
`IF (...) IS NOT TRUE` in the same change.

The reader is `SECURITY DEFINER`, owned by a role with just enough read
privilege on the submission tables and a fixed `search_path`. It checks the
role, subject, and grant id again on its own, loads the grant row, and refuses
if it is revoked or expired, even when the result would be empty. It builds
each row with `jsonb_build_object` from granted values only. There is no
column for `?select=`, ordering, filtering, or embedding to reach, and no
relation the role could embed from, so an ungranted value cannot be recovered
through the query string. Revocation is live because the row is read on every
call; it applies to requests that start after the revoke commits and cannot
recall a response already sent.

Effective privileges, including `PUBLIC` and each creating role's default
privileges, are enumerated by the test suite, so a later migration cannot
widen this role's reach without a test failing.
