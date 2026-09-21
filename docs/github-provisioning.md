# GitHub provisioning: the App, its installation, and the environment

Operator notes for the credential behind self-serve assignment repositories.
The decision and its reasoning are in
[ADR 0006](adr/0006-self-serve-assignment-repositories.md); this page is
what to click and what to set.

Provisioning is optional. With none of the variables below set, authapp
starts, logs one line saying provisioning is disabled, and everything else
works as before.

## Create the App

One App per organization that runs the platform, owned by the organization
(not by a faculty member's account, so it survives them). GitHub: the
organization's *Settings → Developer settings → GitHub Apps → New GitHub
App*.

- **Name**: something a student will recognise on a repository's
  collaborator list, such as "MGT 656 Provisioner".
- **Homepage URL**: the course site.
- **Webhook**: untick *Active*. The platform polls; it does not receive
  events.
- **Permissions**, and nothing beyond these:
  - Repository → *Administration*: **Read and write**. Template generation
    and the collaborator grant.
  - Repository → *Contents*: **Read**. Template generation reads the
    template; the readiness check reads the generated repository's first
    commit. GitHub documents *read* as sufficient for generation; if a
    generate is refused with a permissions message, raise this to *Read and
    write* and record why here.
  - Repository → *Metadata*: **Read**. Every App has this; it is what
    `GET /repos/{org}/{name}` uses.
  - Organization → *Members*: **Read and write**. Reading a student's
    membership state, inviting them, and adding them to the students team.
- **Where can this GitHub App be installed?**: *Only on this account*.

After creation, note the **App ID** shown at the top of the App's settings
page, then under *Private keys* choose *Generate a private key*. GitHub
downloads a `.pem` file once and does not keep a copy. That file is the
secret.

The later student-authorized "join" App (issue #399) is a **separate App**
with *Organization → Members: Read and write* only. Do not add OAuth
callbacks or user authorization to the provisioner; a student is never
asked to authorize it.

## Install it on the organization

From the App's settings, *Install App → your organization*. Choose **Only
select repositories** and select the template repositories. GitHub grants
an installation access to every repository the App itself creates, so the
repositories generated for students are covered automatically; see
[Installing your own GitHub App](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app)
("If the app creates any repositories, the app will automatically be granted
access to those repositories as well"). *All repositories* also works and
needs no upkeep when templates are added, at the cost of the App being able
to administer every repository in the organization.

The installation id is in the URL after installing:
`https://github.com/organizations/<org>/settings/installations/<id>`. That
number is `GITHUB_PROVISIONER_INSTALLATION_ID`.

Every template the platform is allowed to generate from must be a repository
in this organization marked as a template (*Settings → Template repository*)
**and** in the installation's repository list. When a new template is
added to `api.repository_templates`, add its repository to the installation
(*Settings → GitHub Apps → the App → Configure → Repository access*);
forgetting to shows up as `not_found` on generate.

## Environment

Authapp reads these; `docker-compose.base.yaml` passes them through from
`.env`. All of them are optional together and refused half-set.

| Variable | Meaning |
| --- | --- |
| `GITHUB_PROVISIONER_ORG` | The organization repositories are created in. Required to enable provisioning. |
| `GITHUB_PROVISIONER_STUDENTS_TEAM_SLUG` | The team every student is added to after joining, by slug (the last path segment of the team's URL). Optional; leave unset for no team. |
| `GITHUB_PROVISIONER_API_BASE_URL` | Defaults to `https://api.github.com`. Set only for GitHub Enterprise Server (`https://<host>/api/v3`) or a test double. |
| `GITHUB_PROVISIONER_APP_ID` | The App ID from the App's settings page. |
| `GITHUB_PROVISIONER_INSTALLATION_ID` | The installation id from the installation URL. |
| `GITHUB_PROVISIONER_PRIVATE_KEY_FILE` | Path, **inside the authapp container**, to the downloaded `.pem`. |
| `GITHUB_PROVISIONER_TOKEN` | A static token instead of the App. For development, tests, and small deployments only; see below. |

Rules, enforced at startup so a mistake stops the container rather than a
student:

- Provisioning is **enabled** when `GITHUB_PROVISIONER_ORG` and one credential are set,
  and **disabled** (one log line, authapp runs) when either is missing.
- The three App variables (`GITHUB_PROVISIONER_APP_ID`,
  `GITHUB_PROVISIONER_INSTALLATION_ID`, `GITHUB_PROVISIONER_PRIVATE_KEY_FILE`)
  are all-or-nothing. One or two of them is a panic naming the missing ones.
- `GITHUB_PROVISIONER_TOKEN` together with the App variables is a panic. Pick one.
- A key file that cannot be read or is not an RSA private key is a panic.

The private key is mounted read-only, not pasted into an environment
variable: environment variables show up in `docker inspect`, in crash
reports, and in the output of anyone who runs `env` in the container. Put
the `.pem` next to the other production secrets and add a volume to the
`authapp` service in `docker-compose.prod.yaml`:

`docker-compose.prod.yaml` mounts the key read-only at
`/run/secrets/github-provisioner.pem` from whatever
`GITHUB_PROVISIONER_PRIVATE_KEY_HOST_FILE` names on the host (say
`/home/alpine/secrets/github-provisioner.pem`, mode 0600); leave it unset and an
empty placeholder is mounted instead. So `.env` carries
`GITHUB_PROVISIONER_PRIVATE_KEY_HOST_FILE=<host path>` and
`GITHUB_PROVISIONER_PRIVATE_KEY_FILE=/run/secrets/github-provisioner.pem`.
The file should be owned by root and mode `0400`; the container runs as
root, so it can read it.

Production `.env` entries, then, look like:

```sh
GITHUB_PROVISIONER_ORG=yale-mgt-656-fall-2026
GITHUB_PROVISIONER_STUDENTS_TEAM_SLUG=students
GITHUB_PROVISIONER_APP_ID=123456
GITHUB_PROVISIONER_INSTALLATION_ID=78901234
GITHUB_PROVISIONER_PRIVATE_KEY_FILE=/run/secrets/github-provisioner.pem
```

Authapp mints an installation token from the key on first use, caches it in
memory, and mints another five minutes before it expires. Tokens are never
written anywhere and never appear in errors or logs. The names are
deliberately prefixed: a `.env` shared with other tooling that holds a bare
`GITHUB_TOKEN` or `GITHUB_ORG` does not enable provisioning.

## The static token alternative

`GITHUB_PROVISIONER_TOKEN` accepts a fine-grained personal access token with the same
repository and organization permissions as the App, scoped to the
organization's repositories. It exists so the dev stack and a very small
deployment do not have to register an App. Its costs are the ones ADR 0006
lists: it belongs to a person, its lifetime is whatever that person chose,
and rotating it is a manual paste. Do not use one in production for a course
with an enrolment.

## Rotation

To rotate the App's key: in the App's settings, *Generate a private key*
(GitHub allows more than one active key), replace the mounted file with the
new one, restart authapp (`./bin/prod.sh up -d authapp`), confirm the log
line `GitHub provisioning enabled for organization ...` and that a
repository can be created, then delete the old key in GitHub. Installation
tokens already minted from the old key stay valid for up to an hour after
the key is deleted; that is GitHub's behaviour and there is nothing to do
about it except rotate before, not after, a compromise is public.

To rotate a static token: generate a new one, set `GITHUB_PROVISIONER_TOKEN`, restart
authapp, revoke the old one.

To revoke everything at once, uninstall the App from the organization.
Every installation token dies immediately; provisioning fails with
`unauthorized` until it is reinstalled (with a new installation id).

## What to check when it does not work

- `authapp` log at startup says `GitHub provisioning disabled: ...` — one
  of `GITHUB_PROVISIONER_ORG` or the credential is not reaching the container. Check
  `.env` and the compose environment block.
- The container exits at startup with `GitHub provisioning is
  misconfigured` — the message names the variable.
- Errors of kind `unauthorized` on every call — the installation was
  removed, the key was deleted, or the App lacks a permission it needs.
  Re-read *Permissions* above against the App's settings page.
- `not_found` on generate — the template repository is not in the
  installation's repository list, or is not marked as a template.
- `not_found` reading a repository the platform created — GitHub answers
  404 for a private repository the credential cannot see as well as for one
  that does not exist. Check the installation is still on the organization
  and that the repository was not transferred out of it; briefly after
  generation it can also mean the repository has not appeared yet, which the
  readiness handler waits out for a bounded time.
- `rate_limited` — the App's installation has 5,000 requests an hour on a
  paid organization; the error carries the wait GitHub asked for. A class
  clicking at once does not reach that; a loop does.

## HTTP contract

Repositories are a resource with their own page: a student creates one from
a **template** (`api.repository_templates`, configured by faculty) on
`/auth/repositories`, and pastes its address into whatever assignment asks
for a URL. Nothing is written to a submission by the platform (ADR 0006,
*Decoupled from submissions*). The routes are session-authenticated and
exist only when provisioning is enabled; with it disabled they are absent
and answer 404 like any unknown path. Every response carries
`Cache-Control: no-store`.

### `GET /auth/repositories`

The page. Server-rendered from the database alone: rendering it never
calls GitHub and never claims an attempt. A signed-out visitor is sent
through `/auth/login?next=/auth/repositories` and back. It is a student's
page: staff get one line saying so, and nothing is read for them (the
attempt view shows faculty every row, which is exactly why none of it may
be rendered as theirs). For a student, three sections:

1. **GitHub account.** *Connected as `<login>`*, with a *verified* badge
   once the join flow has confirmed the account. Otherwise a **Connect
   your GitHub account** button, which is the join landing page
   ([github-join.md](github-join.md)) returning here; when the join flow is
   not configured, text telling the student to ask staff to record their
   username and to accept the organization's invitation instead. A
   connected but unverified account also gets the button, since one
   authorization verifies it and joins the organization.
2. **Create a repository.** One row per active template the student may
   use: every individual template, plus the team templates when they are
   on a team. Each shows the template's label and description and either
   a **Create** button (a form that POSTs to the create route below) or
   the state known from the rows: *Ready* with the link, *Preparing…* with
   the link (the script polls), *Could not create it last time (`code`)*
   or *A previous attempt was interrupted* with a **Try again** button,
   which is the same POST.
3. **Your repositories.** The rows of `api.my_repositories` -- own and
   current team -- as links, with the template's label.

One external script, `/auth/repositories.js`, submits Create by `fetch`
and re-renders the row from the JSON reply (button disabled while in
flight), then polls the status route every three seconds while the reply
is `copying`, honouring a longer `Retry-After`, until two minutes after
the click; a wait that would end past that deadline is not scheduled, and
a **Check again** button is shown instead (`authapp/static/repositories.js`,
whose delay arithmetic `bun test authapp/static` covers). It never posts on load: the
page is a GET anyone can link to, so the POST is made only when the
student presses the button. Without the script the form posts natively and
the create route sends the browser back to the page with the outcome in
the query (`?template=<slug>&result=<state or code>`), which the page
renders as a one-line notice; `?github_join=<marker>` from the join
callback is rendered the same way.

### `POST /auth/repositories/{template_slug}`

Creates the caller's repository from the template, or resumes creating it.
The body is ignored: the owner (the student, or their current team for a
team template), the template, the repository name
(`<template_slug>-<login>` or `<template_slug>-<team nickname>`) and the
GitHub login all come from the session and the database. The request must
be same-origin (`Sec-Fetch-Site: same-origin`, or an `Origin` matching the
host); anything else is refused with 403 `cross_site_request`. Six clicks
a minute per student are admitted; more get 429 `too_many_requests` with
`Retry-After`.

The reply is JSON for a fetch (`Accept: application/json`, or a browser's
`Sec-Fetch-Mode: cors`) and a 303 back to the page for a form post.

Repeating the POST is safe and is how every interruption is recovered: the
attempt row records the stage reached (`claimed`, `generated`, `granted`,
`finalized`, `failed`), and a click continues from there. Every click on an
unfinished attempt re-validates every owner first (login on record, the
account it resolves to, organization membership) and re-grants push to the
current roster before finalizing, so a change between clicks is seen.
Before a generate the destination name is always looked up: a repository
already there that was generated from the template after the attempt
began is adopted, which is how a generate that timed out after it landed
converges on one repository. Two clicks at once share one attempt and
produce one repository. Finalizing records the `assignment_repository` row
(with the template's `assignment_slug` copied onto it) and nothing else.

### `GET /auth/repositories/{template_slug}`

Reads. It never creates a repository; the one thing it records is when
readiness was last checked. It runs as the student, so row-level security
decides which attempt and repository they may see: a former teammate sees
nothing.

### States

Both per-template routes answer `{"state": ..., "repo_url": ..., "join_url": ...}` on
success. `repo_url` and `join_url` are `null` when not applicable.

| Status | `state` | Meaning |
| --- | --- | --- |
| 200 | `ready` | The mapping is recorded, every owner has push, and the default branch has a commit. `repo_url` is set. |
| 202 | `copying` | The repository exists and is recorded, but GitHub is still copying the template into it (or it has not become visible yet). `repo_url` is set. Poll. |
| 200 | `needs_github_link` | The caller has no GitHub login on record, or the login on record no longer names the linked account. Nothing was created. With the join flow configured ([github-join.md](github-join.md)) `join_url` names the landing page (`/auth/github/join?next=/auth/repositories`) where one GitHub authorization links the verified account and joins the organization; `null` means staff have to record the login. |
| 200 | `needs_org_join` | The caller's GitHub account is not an active member of the course organization. Nothing was created. `join_url` is set when the join flow is configured, and `null` when it is not, which means: ask to be invited. |

### Errors

Anything else is `{"error": {"code": ..., "retryable": bool}}`. `retryable`
means "the same request may succeed later"; a POST is the request to
repeat, including after a `GET` that reported an interruption.

| Status | `code` | When |
| --- | --- | --- |
| 401 | `unauthenticated` | No session. (A form post is sent through login instead.) |
| 403 | `cross_site_request` | The POST did not come from the site. |
| 403 | `not_a_student`, `not_enrolled`, `no_team`, `assignment_closed` | The caller is not eligible, as the database decided. `assignment_closed` applies when the template points at an assignment that has closed for this owner (exceptions included). |
| 404 | `template_not_found`, `template_inactive` | No such template (or a malformed slug), or one faculty have deactivated. |
| 404 | `repository_not_started` | GET only: nothing has been asked for yet; show the button. |
| 409 | `provisioning_interrupted` | GET only, retryable: a POST stopped between checkpoints. Repeat the POST. |
| 409 | `team_prerequisites_incomplete` | Retryable: a teammate has no login on record or is not in the organization. The caller cannot fix it for them. |
| 409 | `name_taken` | A repository with the destination name exists and was not generated from our template after this attempt began. Staff resolve it; nothing is renamed or deleted. |
| 409 | `collaborator_not_member`, `repository_conflict`, `destination_name_too_long` | Conflicts for staff, named by the database or GitHub. A GET after one of these returns the code that was recorded, with `retryable: true`, because a POST resets the attempt and tries again. |
| 200 | `needs_github_link` (after `github_identity_mismatch`) | The database found the account the grant went to is no longer the one linked to the student; the attempt is recorded failed with that code and the student is asked to relink (`join_url` as above). |
| 429 | `too_many_requests` | The per-student admission limit. `Retry-After` is set. |
| 429 | `github_rate_limited` | GitHub is rate limiting the course credential. `Retry-After` carries GitHub's wait, and every GitHub call is refused for that long; work that needs none (a recorded `ready`) still answers. |
| 502 | `github_unavailable` | Retryable: GitHub timed out or failed. After an ambiguous generate the next POST looks the name up before posting again. |
| 502 | `github_credential_rejected` | GitHub refused the course credential; an operator must fix the installation. |
| 502 | `template_not_found`, `template_empty` | The template repository is not in the installation, is not a template, or has no contents. (The same code with a 404 is the database's: no such template row.) |
| 502 | `generate_rejected` | Retryable: GitHub refused the generate although the name was free a moment earlier -- a race, which the next click's lookup settles, or a request GitHub will not honour, which repeats. |
| 502 | `repository_not_visible`, `template_copy_timed_out` | Ten minutes after the attempt began the repository still answers 404, or still has no commits. |
| 502 | `platform_unavailable` | Retryable: PostgREST did not answer. |

### Polling

After a `copying`, GET every three seconds. Never overlap requests: wait for
one to answer before sending the next. Honour a `Retry-After` header when
it is longer than three seconds. Stop automatic polling two minutes after
the click and leave a manual check available; the server keeps answering
`copying` for up to ten minutes before it reports an error. A poll within
three seconds of the last check is answered from the recorded result
without asking GitHub, so several tabs, or several teammates, cost one
GitHub call per interval. The page's script does all of this.

## Verifying the lifecycle

`bun run test_provisioning` (`bin/test-provisioning.sh`) runs
`tests/provisioning/lifecycle.js` against the dev stack with a scripted fake
GitHub, `tests/fake-github/server.js`, standing in for `api.github.com`,
then `bun run test_authapp_static`, the Bun unit test of the page script's
poll arithmetic (`authapp/static/repositories.test.js`). Neither is part of
`bun run test`: the first rebuilds and restarts the `authapp` container
twice -- once with provisioning enabled, every other `GITHUB_PROVISIONER_*`
and `GITHUB_JOIN_APP_*` variable blanked whatever `.env` says, and
`GITHUB_PROVISIONER_API_BASE_URL` pointed at the fake through
`host.docker.internal`; once afterwards with `.env`'s own values back --
and the second belongs with it rather than with the database suites. Like
`test_db` and `test_rest`, the run resets the shared dev database's sample
data. The token it uses, `fake-token`, is a placeholder the fake insists on
and is set in the script's environment, never in `.env`; every response the
suite receives, page included, is checked for it.

The seed is what faculty would do: four rows of `api.repository_templates`
posted through PostgREST -- `exam-1-starter` (individual, tied to `exam-1`),
`project-starter` (team, tied to `project-update-1`), `scratch` (tied to no
assignment) and `retired` (`is_active = false`) -- plus a GitHub login for
every student and a submission the first student had already made to
`exam-1` by hand. `tests/provisioning/demo.js` applies the same seed for a
look at the page by hand; run it after
`YELUKEREST_TEST_KEEP_FAKE=1 bun run test_provisioning` has left the fake
and authapp configured, and sign in as one of the netids it prints.

The fake implements exactly the endpoints `authapp/github.go` calls and is
scripted per scenario through `POST /__fake/state`: accounts, membership
states, existing repositories with their template and creation time, how
many `HEAD` reads a new repository answers 409 to before its contents
exist, whether a collaborator grant is a 204 or a 201 invitation, how long a
generate takes, and one-shot failures on the next generate or grant (500,
secondary rate limit with `Retry-After`, a reply held past the client's
deadline, a reply cut off after the repository was created). `GET
/__fake/calls` is the call log the assertions read: method, path, sanitized
request body, status, and start and finish times. Repository ids are never
reused, across resets included, because the platform refuses one id for two
owners.

What the twelve scenarios establish, taken together:

- **One repository per owner per template, however the clicks arrive.** A
  repeat click after success, a click during another click's generate (the
  fake holds the generate for 1.5 s and the second request is sent while it
  is in flight), and a click after each kind of interruption all end with
  one generate in the call log, one attempt row and one mapping row.
- **Every checkpoint resumes.** An attempt interrupted after generate (the
  first grant fails with a 500) answers `provisioning_interrupted` to a GET
  and resumes from `generated` on the next POST with one more grant and no
  generate; a generate whose reply was cut off after the repository landed
  leaves an attempt with no repository id, and the retry's name lookup
  adopts what landed; a 201 invitation on grant is recorded as
  `collaborator_not_member` and the retry adopts the repository once the
  grant is a 204; a rate-limited generate leaves the attempt at `claimed`,
  the wait is passed on as `Retry-After`, a click inside the wait is refused
  without a GitHub call, and the same attempt id finalizes afterwards with
  the repository id the mapping holds.
- **Refusals generate nothing, grant nothing, and finalize nothing.** A
  deactivated template is refused before anything is claimed: 404 from
  both routes (`template_inactive` to the POST, `template_not_found` to
  the GET), no attempt row, no GitHub call. Every other refusal comes
  after the claim, because the attempt is the checkpoint the checks are
  recorded on: a pending membership answers `needs_org_join` with the
  attempt left at `claimed`, and a destination name held by a repository
  from another template answers `name_taken`, recorded on the attempt as
  its `error_code` so the GET can report it. In every case the call log
  shows no generate and no grant, and no mapping row exists afterwards.
- **What is recorded is the mapping and nothing else.** After every success
  the mapping's `provider_repo_id` equals the attempt's, the mapping and
  the attempt carry the template's `assignment_slug` (NULL for `scratch`),
  and `api.my_repositories` lists the row with its label and `repo_url`.
  The submission the first student had made to `exam-1` before clicking is
  byte-for-byte what it was afterwards -- same rows, same `origin`, same
  event ledger -- and no team submission appears for a team repository. On
  a team template each teammate's grant carries `permission: push` against
  the same repository path, either teammate's GET answers `ready`, and a
  student on another team sees none of it through the routes, through
  `api.assignment_repositories`, `api.repository_provisionings` or
  `api.my_repositories`.
- **The page is the database, rendered.** Signed out, `GET
  /auth/repositories` is a redirect through login. A student on a team sees
  every active template's label with a Create form, not the retired one,
  their connected login, and *None yet*; rendering it makes no GitHub call
  and claims no attempt. A native form post (no JSON `Accept`) answers 303
  to `/auth/repositories?result=ready&template=<slug>`, and the page then
  shows the notice, the row as *Ready* with the link and no Create form,
  the repository under *Your repositories*, and Create still offered for
  the other templates. `/auth/repositories.js` is served as JavaScript.
  Faculty get the students-only page with no template on it.

It does not exercise the join flow (`docs/github-join.md`), a template
that is missing or empty on GitHub, a closed assignment, or the ten-minute
readiness grace; the Go tests in `authapp/` cover those branches against an
in-process fake, and `tests/db` covers `assignment_closed`. Live-GitHub
smoke runs are operational work done by hand against a scratch
organization, not part of any suite here.

## Enablement order

Each step can be left in place before the next. The one that changes what a
student sees is activating a template (step 5): a template row is staged
with `is_active = false`, which nobody but faculty can see, and the `PATCH`
that sets it `true` is the only switch that puts it on students'
repositories pages. The pilot is therefore one template activated in a
short, announced window, or a template made for the purpose and
deactivated afterwards.

1. **Deploy the code.** `./bin/deploy-prod.sh --deploy --services "authapp
   elmclient"` applies the pending migrations through
   `01a0bb0d-…-add-assignment-repository-provisioning` and rebuilds and
   restarts the two services whose source changed. `api.platform_version`
   then reports `schema_compatibility_version` 8 and `admin_api_version`
   15. A plain `./bin/prod.sh up -d authapp` without `--build` restarts the
   **old** image and the routes stay absent. Nothing is enabled yet:
   authapp without a credential logs `GitHub provisioning disabled`.
2. **Credential.** Create and install the App (above), set the
   `GITHUB_PROVISIONER_*` variables, restart authapp, and confirm the log line
   `GitHub provisioning enabled for organization "…"`. The repositories
   page now exists, with no templates on it.
3. **Import logins.** For a course that already collected GitHub usernames
   through an assignment field, faculty run
   `POST /rest/rpc/import_github_logins` with `p_assignment_slug` and
   `p_field_slug`. It fills `github_login` for every student who has none,
   skipping malformed and contested values, and returns the count. Students
   it skipped will be told `needs_github_link` on their first click, which
   is the correct answer for them. The RPC is idempotent; run it again after
   more usernames come in.
4. **Stop every other writer.** A course migrating from an external
   provisioner (the cutover checklist below) disables its cron here, before
   any template is added.
5. **Pilot with one template: stage it, then activate it.** Faculty
   `POST /rest/repository_templates` with a faculty bearer token and a
   body like

   ```json
   {
     "slug": "exam-1-starter",
     "label": "Exam 1 starter",
     "description": "Starter code for the first exam.",
     "template_full_name": "yale-mgt-656-fall-2026/exam-1-starter",
     "is_team": false,
     "assignment_slug": "exam-1",
     "is_active": false
   }
   ```

   `slug` is the key and the first half of every repository name made from
   the template; `template_full_name` is `<org>/<template>` on GitHub;
   `description` and `assignment_slug` are optional (the assignment's
   deadline, extensions included, is what closes the template; a team
   template can only name a team assignment); `provider` defaults to
   `github`. `is_active` defaults to `true`, so it is stated as `false`
   here on purpose: the staged row is invisible to students, and can be
   checked (the template is marked as a template on GitHub and is in the
   installation's repository list) before anyone can click. Then

   ```
   PATCH /rest/repository_templates?slug=eq.exam-1-starter
   {"is_active": true}
   ```

   is the only exposure switch. From that moment the template is on every
   student's repositories page (team templates only for students on a
   team). Have two people click in
   the window: one student who **already has** a mapping row for the
   template (the click must answer `ready` for the existing repository and
   generate nothing) and one who does not (expect `copying` then `ready`,
   the repository in the organization with push for that account, and a
   row in `api.my_repositories`). Then each clicks again and confirms
   nothing new was created. Roll back (below) if anything is off; it costs
   nothing.
6. **Roll out.** Stage the remaining templates the same way, with
   `"is_active": false`, and activate each with the same `PATCH` when its
   assignment is ready for students. There is no separate UI switch;
   `is_active` is the switch, in both directions.

## Consumer cutover checklist for `yale-mgt-656-fall-2026/admin`

Editing the course repository is consumer work and stays there; this is
the order it has to happen in, from the platform's side. Everything below
refers to that repository's `admin provision-repos` command and the cron
`scripts/install-provision-cron-on-server.sh` installs.

- [ ] **Preflight the version.** `GET /rest/platform_version` must report
      `schema_compatibility_version` in the consumer's supported set, which
      has to include `8`, and `admin_api_version >= 15`. Membership for the
      shape, a floor for the RPCs; `docs/platform-compatibility.md` says why.
- [ ] **Keep the existing mappings.** Rows `admin provision-repos` wrote to
      `api.assignment_repositories` are reused as they are:
      `claim_repository_provisioning` finds the row for the owner and answers
      `finalized` without creating an attempt, and the GET route reports the
      recorded repository. Do not delete or rewrite them, and do not run a
      "re-provision"; a row with the wrong `provider_repo_id` is fixed by
      hand (see *Staff recovery*).
- [ ] **Validate the URL patterns.** The student pastes
      `https://github.com/<org>/<template_slug>-<login>` (or
      `-<team nickname>` for a team template) into the assignment's URL
      field themselves, or takes the one-click fill the assignment page
      offers when a repository of theirs names that assignment; the
      field's `pattern` is what checks it, as for any pasted URL. Check
      each field's pattern against a real login before anyone clicks. A
      pattern written for Classroom-style names is the usual culprit.
- [ ] **Replace Classroom links.** Assignment text that pointed at a GitHub
      Classroom invitation points at `/auth/repositories` instead, and
      tells the student to paste the address into the field.
- [ ] **Disable the cron BEFORE any template is added.** Remove
      the crontab entry (the `UNTIL` mechanism in the install script, or
      `crontab -e` on the server) and confirm no run is in flight. The cron
      and a student click both create `<slug>-<login>`; a cron run that
      lands between a student's lookup and generate produces `name_taken`
      for the student and a duplicate row for the cron, and the row has to
      be sorted out by hand. Once a template exists the platform must be
      the only writer for it.
- [ ] **Stage the templates, then activate them**, one first (the pilot
      above), then the rest, as rows of `api.repository_templates` in the
      course's fixtures: a `slug` (which is the prefix of every repository
      name), `label`, `template_full_name = '<org>/<template>'`, `is_team`,
      the `assignment_slug` whose deadline should close it, and
      `is_active = false` until the row has been checked. The migration
      backfilled a template per assignment that already had mapping rows,
      inactive, with `template_full_name = 'unknown/<slug>'`; fix those up
      before activating them. The template must be marked as a template on
      GitHub and be in the App installation's repository list. The `PATCH`
      to `is_active = true` is what exposes the button, and nothing else
      does.
- [ ] **Keep the CLI as the staff fallback.** `admin provision-repos`
      stays installed for a staff member to run **by hand, once, for one
      assignment** when GitHub is refusing the platform's credential or a
      student cannot be unblocked any other way. It is never put back on a
      cron.

Production GitHub smoke runs (a real template, a real student account, a
scratch organization) are separate operational work done before the first
assignment goes live, not something this repository automates.

## Rollback

To stop new provisioning from a template: faculty
`PATCH /rest/repository_templates?slug=eq.<slug>` with `{"is_active":
false}`, the same switch as activation, the other way. The row disappears
from the repositories page on its next load, the POST
answers `template_inactive`, and the GET answers `template_not_found` for
anyone without a repository. **Nothing else changes**: every
`assignment_repositories` row stays, and a student whose repository was
already made keeps it and still sees it under *Your repositories*.
Submissions were never written by the platform, so there is nothing to
undo there. To stop it for every template at once, unset the credential
and restart authapp; the routes are then absent altogether.

Do **not** restart the old cron after a rollback without reconciling first:
the platform will have made repositories the cron does not know about, and
the cron keys on names. Reconcile by reading `api.assignment_repositories`
for the assignment and confirming the cron's own record (or its dry run)
agrees with every `provider_repo_id` before it is allowed to write again.

## Staff recovery

Recovery always starts from what was recorded -- the attempt's
`provider_repo_id` in `api.repository_provisionings`, the
mapping's in `api.assignment_repositories` -- never from a repository's
name. Names are guessable and reattach to whatever holds them next; the ids
do not.

- **Interrupted attempt** (GET says `provisioning_interrupted`, or the
  attempt is at `claimed`, `generated` or `granted`): the student clicks
  again. The POST resumes from the recorded stage, re-validates every owner,
  re-grants push, and finalizes; a generate that landed without a recorded
  id is found by the name lookup and adopted when it was made from our
  template after the attempt began. Staff do nothing unless the second
  click also fails, in which case the recorded `error_code` names what to
  fix.
- **Unrelated repository holds the name** (`name_taken`): a repository
  called `<template_slug>-<login>` exists in the organization and was not
  generated from the template after the attempt began. The simple fix is
  to rename the stray repository on GitHub; the student's next click then
  generates. If it is in fact the student's repository and should be kept,
  record it by hand: a mapping row in `api.assignment_repositories` with
  the `template_slug`, the owner, and the repository's numeric id from
  `GET /repos/<org>/<name>` as `provider_repo_id`. Once it exists the claim
  reports the repository as finalized and the page lists it. Never delete
  the stray repository from here; it may be somebody's work.
- **Wrong URL in an assignment field**: that is the student's own
  submission, edited the way any submission is; the platform never wrote
  it and never checks it against the mapping.
- **Credential failure** (`github_credential_rejected` to the student; the
  one line authapp logs as `provisioning: ERROR GitHub refused the course
  credential`): the installation was removed, the key deleted, or a
  permission dropped. Follow *What to check when it does not work* above;
  `bun run doctor` confirms the rest of the stack is healthy while you do.
  Attempts that failed with it are resumed by the student's next click
  once the credential works; nothing needs resetting.
