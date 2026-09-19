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
