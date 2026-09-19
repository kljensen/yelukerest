# ADR 0006: Self-Serve Assignment Repositories Run In Authapp On A GitHub App Credential

## Status

Accepted, 2026-09-19. Records the decisions behind milestone "Roadmap 17:
Self-Serve Assignment Repositories" (issues #393–#399). This ADR and the
GitHub client land first (#393); the schema, the endpoints, the Elm client,
and the student-authorized join flow follow in the milestone's later issues
and are described here as decided, not as built.

## Context

Until now a course repository provisioned student repositories from the
outside: `yale-mgt-656-fall-2026/admin` runs `admin provision-repos` on a
cron, reads the roster and the typed GitHub usernames out of this platform,
creates one private repository per student from a template, grants push, and
writes the mapping back into `api.assignment_repositories`. It works, and it
has three problems that are all the same problem.

It runs on a **faculty personal access token** for GitHub, held in the course
repository's environment. The token is a person: it can do whatever that
person can do to every organization they belong to, it expires when they say
it does, and rotating it means a human generating a new one and pasting it
somewhere. ADR 0002 and ADR 0005 already turned this platform away from
person-credentials for services; this is the last one standing.

It is **batch**, so a student who submits their username after the cron has
run waits for the next run, and one who mistyped it waits for a human. The
assignment page cannot say "your repository is being made" because nothing on
the platform is making it.

And the **invariants live in the wrong place**. The course tool decides
whether a student is enrolled, whether the assignment is open, whether a
team's roster is current, and whether a mapping row already exists, by
reading the platform's tables and reasoning about them in Go, at a distance,
without a transaction. Every one of those is a rule the platform already
enforces in SQL for every other write, with row-level security and
constraints (`CLAUDE.md`, ADR 0003). Reproducing them in a consumer means
they drift.

What the platform has today: `data.assignment_repository` with identity by
provider repository id and uniqueness per owner and per repository
(`migrations/01a011e3-*-add-assignment-repository/`); a
`data.assignment_field_submission.origin` column whose values include
`provisioning`, with a trigger that refuses a student setting any origin but
`student` (`migrations/01a05ac3-*-add-field-submission-origin/`); an `app`
role with `request.app_name()` that service-only RPCs already check for
`authapp` (`issue_user_jwt` in the bootstrap migration); and authapp itself,
a Go service that owns the browser session, talks to PostgREST over HTTP with
`AUTHAPP_JWT`, and holds exactly one direct database connection, for
sessions. That is the boundary this ADR builds on.

## Decision

**The provisioning credential is a GitHub App installation token.** The
platform is registered as a GitHub App, installed on the course
organization. Authapp holds the App's id, the installation id, and the App's
RSA private key (mounted read-only from a file, never an environment
variable). It signs a short-lived JWT with the key, exchanges it for an
installation access token that lasts an hour, and caches that token in
server memory until five minutes before it expires; concurrent requests that
find the cache stale wait for one refresh. Nothing durable ever holds a
token: not the database, not the session store, not a response, not a log
line.

The App is the credential the deployment guide describes and the one
production uses. A **static token** (`GITHUB_PROVISIONER_TOKEN`) is accepted
behind the same interface, for development, for tests, and for a small
deployment whose operator decides a fine-grained token they rotate by hand is
acceptable. The two are mutually exclusive in configuration; setting both is
refused at startup, as is setting some but not all of the App variables,
because either means someone meant to enable provisioning and would
otherwise find out when a student clicked. Setting neither, or omitting the
organization, disables provisioning with one log line and authapp starts
normally. Every variable carries the `GITHUB_PROVISIONER_` prefix so a
`.env` shared with other tooling that happens to hold a bare `GITHUB_TOKEN`
cannot enable provisioning by accident.

The App asks for the least GitHub will accept for the job: repository
**Administration: write** and **Contents: read**, which GitHub documents as
what template generation and the collaborator grant require, and which also
cover reading the generated repository's first commit for readiness;
**Metadata: read**, which every App has; and organization **Members:
write**, for inviting a student and adding them to the students team. It is
installed on the **template repositories only**. That is enough: GitHub
grants an installation access to every repository the App itself creates,
whatever the installation's repository list says
([Installing your own GitHub App](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app)),
so the repositories generated for students are covered without widening
the installation to the whole organization.

**The later "join" App is a second App, not more permissions on this one.**
Issue #399 lets a student authorize an App with their own GitHub account so
the platform can learn their numeric GitHub id and accept an organization
invitation on their behalf. That App requests **Organization members: write**
and nothing else. A student is asked to trust it with their account, and what
they are trusting it with should be readable on one screen; the provisioner's
repository permissions have no business on that screen. The two credentials
are configured separately and the client keeps them distinct; a call made
with a student's transient token is never made with the course credential and
the reverse.

**Authapp orchestrates GitHub; SQL owns the rules and the final write.**
Authapp is where the network calls happen, because it already has the
session, the service credential, and the HTTP position under `/auth/*`. It
resolves the student and team from the session, asks GitHub who a login is,
whether they are in the organization, generates the repository, grants push,
and polls readiness. It decides nothing about eligibility. Whether the
assignment accepts repositories, whether the student is enrolled and on the
team they claim, whether the deadline (with the student's exceptions) has
passed, whether an attempt or a mapping already exists, and what the
repository is called are all answered by **service-only RPCs** in schema
`api`, `SECURITY DEFINER`, executable by the `app` role alone, checking
`request.user_role() = 'app' AND request.app_name() = 'authapp'` and acting
on a user id passed as an argument, exactly as `issue_user_jwt` does. The
last of them **finalizes in one transaction**: it inserts the
`assignment_repository` row, creates or reuses the `assignment_submission`,
and writes the repository URL into the assignment's designated field with
`origin = 'provisioning'`. Either all three land or none do, and a student
cannot forge that origin because the existing trigger refuses it from their
role. Authapp's session database connection gains no privileges; business
writes go through PostgREST as they always have.

**Partial failure is recovered from a durable attempt row, not a lease.** A
GitHub call can time out after it took effect; authapp can restart between
generate and grant; two teammates can click at once. The answer is one row
per attempt, keyed the same way as the mapping (assignment and student, or
assignment and team, so the uniqueness constraint is the lock), carrying the
stage reached (`claimed`, `generated`, `granted`, `finalized`, `failed`), the
provider repository id once known, and a sanitized error code. Every GitHub
call happens outside a database transaction, and each stage is checkpointed
after the call that completes it. A request that finds an attempt in
progress resumes it; one whose `updated_at` is more than a few minutes old
and not finalized is presumed abandoned and may be resumed by whoever comes
next. There are no lease tokens, heartbeats, or workers to expire them: the
only actor is the next request, and the checkpoints tell it where to start.
After an ambiguous generate, the next request looks the name up before it
ever posts again, and adopts what it finds only if it was created after the
attempt and from our template. A repository is never deleted automatically.

**Names are for people; identity is the provider id.** A repository is
named `<assignment_slug>-<github_login>` for an individual assignment and
`<assignment_slug>-<team_nickname>` for a team one, the convention the
assignment texts already state. The name is how a student finds it and how
an ambiguous generate is reconciled; it is not how anything is keyed. The
mapping row's identity is `provider_repo_id`, as the existing table already
insists, and a student's identity is their numeric GitHub id, checked against
`GET /users/{login}` before every generate so a login that has been renamed
or handed to someone else is a mismatch, not a silent rebinding. A name that
is already taken by a repository that is not ours is a conflict for staff to
look at, not something to route around with a suffix.

**The GitHub client is small, typed, and sanitized.** One client in authapp
(`authapp/github.go`) with a configurable base URL, so every test runs
against `httptest` and none reaches api.github.com. It pins
`X-GitHub-Api-Version: 2022-11-28`, bounds every request, and returns a
classified error (not found, rate limited with the wait GitHub asked for,
unauthorized, conflict, server error, timeout, cancelled) that keeps the
operation, the status, and GitHub's request id, and nothing GitHub said:
the response body is read for classification and dropped, so nothing from
it can reach a log or a client. Redirects are not followed, because Go
would re-send the body. A `GET` is replayed once on a 5xx; nothing else is
replayed by the client, because a `POST` that timed out may have landed and
the caller, not the transport, decides what to do about that.

## Consequences

Easier: a student gets a repository when they ask for one, on the assignment
page, with a state they can watch. The credential is the platform's, scoped
to one organization, rotated by generating a new key in GitHub's UI and
restarting authapp, with nobody's personal account in the loop. Eligibility
and uniqueness are the same rules every other write obeys, enforced once, in
SQL. The course repository stops carrying GitHub credentials and stops
reimplementing enrollment; it configures a template per assignment and reads
the mapping.

Harder: authapp is now a service with a network dependency on GitHub and has
to be honest about GitHub's failure modes, which the attempt row and the
readiness contract (issue #396) exist to make visible rather than to hide.
The App's private key is a secret the deployment has to mount and protect.
Adding a template repository means adding it to the installation as well as
marking it a template, and forgetting the first shows up as `not_found` on
generate. Until issue #399 lands, a student who is not yet in the
organization has to be invited the way they are today.

Deliberately not done: a faculty personal access token as the production
credential, for the reasons in Context; leases or a background worker, when
the next request is a sufficient actor; automatic deletion of anything on
GitHub; replaying a `POST` from inside the client; and a single App for both
the platform's provisioning and the student's authorization.

## Related Decisions

- [ADR 0002: Authentication For Admin API Commands](0002-admin-api-authentication.md)
  set the direction away from a person's long-lived credential in a service's
  environment; this ADR applies it to the GitHub side.
- [ADR 0003: The Write Scope And RLS Are The MCP Write Boundary](0003-mcp-write-boundary.md)
  is the same argument for keeping rules in SQL and letting the service be
  transport; the service-only RPCs here are that boundary for a service
  rather than a student.
- [ADR 0004: Students See The Course's Name](0004-course-name-not-platform-name.md)
  governs how the assignment page names the course when it shows repository
  state; nothing here changes it.
- [ADR 0005: Apps That Consume Course Data Get A Grant, Not A Person's Credential](0005-data-grants-for-consuming-apps.md)
  is the read-side precedent: a consumer gets a credential that is the
  platform's, scoped to a job, never a person's.

## References

- `docs/github-provisioning.md` — creating and installing the App, the
  environment variables, rotation.
- `authapp/github.go`, `authapp/github_test.go` — the client this ADR
  describes and the fake-server tests that hold it to the failure modes above.
- `migrations/01a011e3-29f7-70c0-969c-b289cab26e1f-add-assignment-repository/` —
  the mapping table whose identity and uniqueness rules this builds on.
- `migrations/01a05ac3-03cd-7df2-b1d7-971f89716b96-add-field-submission-origin/` —
  `origin = 'provisioning'` and the trigger that keeps students from claiming it.
- `docs/admin-api.md`, *Assignment Repositories* — the consumer-facing
  description of the mapping.
- GitHub, [Create a repository using a template](https://docs.github.com/en/rest/repos/repos#create-a-repository-using-a-template),
  [Generating an installation access token](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app).
- Issues #393 (this ADR and the client), #394 (schema and RPCs), #395
  (creation), #396 (readiness), #397 (Elm), #398 (lifecycle verification and
  consumer cutover), #399 (the join App).
