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
**and** in the installation's repository list. When a new assignment gets a
new template, add it to the installation (*Settings → GitHub Apps → the App
→ Configure → Repository access*); forgetting to shows up as `not_found` on
generate.

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

```yaml
services:
  authapp:
    volumes:
      - '/path/on/host/provisioner.pem:/run/secrets/github-app.pem:ro'
```

with `GITHUB_PROVISIONER_PRIVATE_KEY_FILE=/run/secrets/github-app.pem` in `.env`.
The file should be owned by root and mode `0400`; the container runs as
root, so it can read it.

Production `.env` entries, then, look like:

```sh
GITHUB_PROVISIONER_ORG=yale-mgt-656-fall-2026
GITHUB_PROVISIONER_STUDENTS_TEAM_SLUG=students
GITHUB_PROVISIONER_APP_ID=123456
GITHUB_PROVISIONER_INSTALLATION_ID=78901234
GITHUB_PROVISIONER_PRIVATE_KEY_FILE=/run/secrets/github-app.pem
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

The assignment page talks to two session-authenticated routes in authapp
(issues #395 and #396). They exist only when provisioning is enabled; with
it disabled they are absent and answer 404 like any unknown path. Every
response carries `Cache-Control: no-store`.

### `POST /auth/assignments/{slug}/repository`

Creates the caller's repository for the assignment, or resumes creating it.
The body is `{}` and is ignored: the owner (the student, or their team for a
team assignment), the template, the repository name and the GitHub login all
come from the session and the database. The request must be same-origin
(`Sec-Fetch-Site: same-origin`, or an `Origin` matching the host); anything
else is refused with 403 `cross_site_request`. Six clicks a minute per
student are admitted; more get 429 `too_many_requests` with `Retry-After`.

Repeating the POST is safe and is how every interruption is recovered: the
attempt row records the stage reached (`claimed`, `generated`, `granted`,
`finalized`, `failed`), and a click continues from there. Every click on an
unfinished attempt re-validates every owner first (login on record, the
account it resolves to, organization membership) and re-grants push to the
current roster before finalizing, so a change between clicks is seen.
Before a generate the destination name is always looked up: a repository
already there that was generated from the assignment's template after the
attempt began is adopted, which is how a generate that timed out after it
landed converges on one repository. Two clicks at once share one attempt
and produce one repository.

### `GET /auth/assignments/{slug}/repository`

Reads. It never creates a repository and never writes a submission; the one
thing it records is when readiness was last checked. It runs as the student,
so row-level security decides which attempt and repository they may see: a
former teammate sees nothing.

### States

Both routes answer `{"state": ..., "repo_url": ..., "join_url": ...}` on
success. `repo_url` and `join_url` are `null` when not applicable.

| Status | `state` | Meaning |
| --- | --- | --- |
| 200 | `ready` | The mapping is recorded, every owner has push, and the default branch has a commit. `repo_url` is set. |
| 202 | `copying` | The repository exists and is recorded, but GitHub is still copying the template into it (or it has not become visible yet). `repo_url` is set. Poll. |
| 200 | `needs_github_link` | The caller has no GitHub login on record, or the login on record no longer names the linked account. Nothing was created. |
| 200 | `needs_org_join` | The caller's GitHub account is not an active member of the course organization. Nothing was created. `join_url` is `null` until the join flow (issue #399) exists, which means: ask to be invited. |

### Errors

Anything else is `{"error": {"code": ..., "retryable": bool}}`. `retryable`
means "the same request may succeed later"; a POST is the request to
repeat, including after a `GET` that reported an interruption.

| Status | `code` | When |
| --- | --- | --- |
| 401 | `unauthenticated` | No session. |
| 403 | `cross_site_request` | The POST did not come from the site. |
| 403 | `not_a_student`, `not_enrolled`, `no_team`, `assignment_closed` | The caller is not eligible, as the database decided. |
| 404 | `repository_not_configured` | The assignment does not exist, is a draft, or has no template. |
| 404 | `repository_not_started` | GET only: nothing has been asked for yet; show the button. |
| 409 | `provisioning_interrupted` | GET only, retryable: a POST stopped between checkpoints. Repeat the POST. |
| 409 | `team_prerequisites_incomplete` | Retryable: a teammate has no login on record or is not in the organization. The caller cannot fix it for them. |
| 409 | `name_taken` | A repository with the destination name exists and was not generated from our template after this attempt began. Staff resolve it; nothing is renamed or deleted. |
| 409 | `collaborator_not_member`, `repository_conflict`, `submission_conflict`, `url_pattern_mismatch`, `repo_url_mismatch`, `destination_name_too_long` | Conflicts for staff, named by the database or GitHub. A GET after one of these returns the code that was recorded, with `retryable: true`, because a POST resets the attempt and tries again. |
| 200 | `needs_github_link` (after `github_identity_mismatch`) | The database found the account the grant went to is no longer the one linked to the student; the attempt is recorded failed with that code and the student is asked to relink. |
| 429 | `too_many_requests` | The per-student admission limit. `Retry-After` is set. |
| 429 | `github_rate_limited` | GitHub is rate limiting the course credential. `Retry-After` carries GitHub's wait, and every GitHub call is refused for that long; work that needs none (a recorded `ready`) still answers. |
| 502 | `github_unavailable` | Retryable: GitHub timed out or failed. After an ambiguous generate the next POST looks the name up before posting again. |
| 502 | `github_credential_rejected` | GitHub refused the course credential; an operator must fix the installation. |
| 502 | `template_not_found`, `template_empty` | The template is not in the installation, is not a template, or has no contents. |
| 502 | `generate_rejected` | Retryable: GitHub refused the generate although the name was free a moment earlier -- a race, which the next click's lookup settles, or a request GitHub will not honour, which repeats. |
| 502 | `repository_not_visible`, `template_copy_timed_out` | Ten minutes after the attempt began the repository still answers 404, or still has no commits. |
| 502 | `platform_unavailable` | Retryable: PostgREST did not answer. |

### Polling

After a `copying`, GET every three seconds. Never overlap requests: wait for
one to answer before sending the next. Honour a `Retry-After` header when
it is longer than three seconds. Stop automatic polling two minutes after
the click and leave a manual retry (a fresh POST) available; the server
keeps answering `copying` for up to ten minutes before it reports an error.
A poll within three seconds of the last check is answered from the recorded
result without asking GitHub, so several tabs, or several teammates, cost
one GitHub call per interval.
