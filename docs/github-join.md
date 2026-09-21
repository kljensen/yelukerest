# GitHub join: the student-authorized App and self-service organization joining

Operator notes for the second GitHub App behind self-serve assignment
repositories: the one a student authorizes with their own account so the
platform can verify which GitHub account is theirs and accept the course
organization's invitation on their behalf. The decision is in
[ADR 0006](adr/0006-self-serve-assignment-repositories.md) ("The later
'join' App is a second App, not more permissions on this one"); the
provisioner itself is in [github-provisioning.md](github-provisioning.md).
This page is what to click and what to set.

The join is optional on top of provisioning. Without it, provisioning still
works: a student who is not an active member of the organization is told
`needs_org_join` with `join_url: null` and has to be invited by hand, and
one with no usable login on record is told `needs_github_link` with
`join_url: null` and staff record it. With it, both answers carry a
`join_url`, and one GitHub screen settles both: the callback records the
verified account first and the membership second, so a student with no
login on file, a stale login, or no membership all take the same link.

## Why a second App

A student is asked to trust this App with their account, and what they are
trusting it with has to be readable on GitHub's one authorize screen. That
screen lists the App's permissions; the provisioner's repository permissions
have no business on it. So the join App asks for **Organization → Members:
Read and write** and nothing else, and the provisioner is never something a
student authorizes.

Authapp uses the App for user authorization only, OAuth-style: the student
authorizes it, GitHub hands authapp a user access token, and authapp
redeems it within one request. Authapp holds no private key for it and
mints no installation token; its only credential for this App is the
client id and client secret used to redeem the authorization code.

The App must nevertheless be **installed on the course organization**. A
user access token can act on an organization's resources only where the
App is installed and only within the permissions the installation was
granted, intersected with what the user can do themselves; authorization
alone grants nothing on the organization, and the accept step
(`PATCH /user/memberships/orgs/{org}`) answers 403 without the
installation. See
[Authenticating with a GitHub App on behalf of a user](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user).
The installation grants the App *no repositories*; nothing in authapp uses
its installation id or key.

## Create the App

On the same organization as the provisioner, *Settings → Developer settings
→ GitHub Apps → New GitHub App*.

- **Name**: what the student will see on the authorize screen and, later,
  under their account's *Applications → Authorized GitHub Apps*. Name the
  course, for example "MGT 656 Organization Join".
- **Homepage URL**: the course site.
- **Callback URL**: `https://<FQDN>/auth/github/callback`, exactly. GitHub
  refuses an authorization whose `redirect_uri` does not match this, and
  authapp builds that value from the scheme and host the proxy forwarded,
  so it must be the public origin.
- **Expire user authorization tokens**: either setting works. Authapp uses
  the token within one request and never keeps it, so a refresh token is
  never used.
- **Request user authorization (OAuth) during installation**: leave
  unticked. That option prompts the *installer* to authorize at install
  time; here the installer is an organization owner and the people who
  authorize are students, from the repositories page.
- **Enable Device Flow**: leave unticked.
- **Webhook**: untick *Active*.
- **Permissions**: Organization → *Members*: **Read and write**. Nothing
  under Repository beyond the *Metadata: Read* every App carries, and
  nothing under Account.
- **Where can this GitHub App be installed?**: *Only on this account*.

After creation, note the **Client ID** at the top of the App's settings and
generate a **client secret** under *Client secrets*. GitHub shows the secret
once. Do not generate a private key; authapp has nowhere to put one for
this App.

## Install it on the organization

From the App's settings, *Install App → your organization*. Under
*Repository access* choose **Only select repositories** and select
**none**: the App needs the organization permission only. The installation
id GitHub shows afterwards is not used anywhere; there is no environment
variable for it. What the installation does is make the organization a
place the App, and therefore a student's token for it, is allowed to act:
without it every accept fails with 403 and the student sees
`error:authorization_failed`.

## Environment

Authapp reads these. They are optional together and refused half-set.

| Variable | Meaning |
| --- | --- |
| `GITHUB_JOIN_APP_CLIENT_ID` | The join App's Client ID. |
| `GITHUB_JOIN_APP_CLIENT_SECRET` | The join App's client secret. |
| `GITHUB_JOIN_APP_AUTHORIZE_URL` | Defaults to `https://github.com/login/oauth/authorize`. For GitHub Enterprise Server (`https://<host>/login/oauth/authorize`) or a test double. |
| `GITHUB_JOIN_APP_TOKEN_URL` | Defaults to `https://github.com/login/oauth/access_token`. Same. |
| `GITHUB_JOIN_APP_API_BASE_URL` | Defaults to the provisioner's `GITHUB_PROVISIONER_API_BASE_URL`. The host the student's token is used against (`GET /user`, `PATCH /user/memberships/orgs/{org}`). |

Rules, enforced at startup:

- The join is **enabled** when provisioning is enabled and both
  `GITHUB_JOIN_APP_CLIENT_ID` and `GITHUB_JOIN_APP_CLIENT_SECRET` are set.
- One of the two without the other is a panic.
- Both set while provisioning is disabled is a panic: the join is a step of
  provisioning, and inviting the student and adding them to the team is
  done with the provisioner's credential and organization.
- Neither set is disabled: one log line when provisioning is on, nothing
  when it is off too. The join routes are not registered at all when
  disabled; they answer 404.

The organization and the students team come from
`GITHUB_PROVISIONER_ORG` and `GITHUB_PROVISIONER_STUDENTS_TEAM_SLUG`; the
join App has no settings of its own for them.

Production `.env` entries look like:

```sh
GITHUB_JOIN_APP_CLIENT_ID=Iv1.0123456789abcdef
GITHUB_JOIN_APP_CLIENT_SECRET=…
```

`docker-compose.base.yaml` passes all five variables through to the authapp
service; nothing else in the compose files changes.

The three URLs must be `https` unless `DEVELOPMENT` is enabled or the host
is loopback or `host.docker.internal`; anything else is a panic at startup.
The client secret travels to the token URL and the student's token comes
back from it.

## The flow

1. The student presses **Connect your GitHub account** on the
   repositories page (`/auth/repositories`, [github-provisioning.md](github-provisioning.md)),
   or presses *Create* there and is told they have no usable GitHub login
   on record (`needs_github_link`) or that their account is not an active
   organization member (`needs_org_join`); both replies carry
   `join_url: "/auth/github/join?next=/auth/repositories"`.
2. That URL is a small page on this origin with an explanation and a
   *Continue to GitHub* button. `next` is where the callback will return
   to: the repositories page by default, or a client route (`/#/…`) when
   an assignment page offered the join; anything else -- another origin,
   another path on this site -- is refused with a 400 rather than
   defaulted, so a link built wrong is noticed. On the click (only then; a
   link to the page starts nothing by itself) its script POSTs to
   `/auth/github/join/start` (same-origin only, like the create POST) and
   follows the `authorization_url` it gets back. Students only: staff are
   refused with `not_a_student`, at start and again at the callback,
   since the join links an identity and adds the account to the students
   team. The POST mints a
   random, single-use `state` and a PKCE code verifier, stores both in the
   student's session together with their user id, netid, the validated
   `next`, the `redirect_uri`, and a timestamp, and builds the GitHub
   authorize URL: `client_id`, `redirect_uri`, `state`, `code_challenge`
   (S256) with `code_challenge_method`, and **no `scope`** (a GitHub App's
   user token carries the App's permissions; scopes are an OAuth-App
   concept).
3. GitHub shows the student one screen naming the App and its one
   permission. They click *Authorize*. (Or they do not; see Denial below.)
4. GitHub sends the browser to `/auth/github/callback?code&state`. Authapp
   requires the session and refuses with a 400 anything that does not match
   the pending state in it: a state this session never minted, one minted
   for another user, one already used, or one older than ten minutes.
   Nothing is done for a refused callback and GitHub is not contacted. A
   callback whose state does not match leaves the pending state in place,
   so a stray hit cannot cancel the authorization the student is in the
   middle of; a matching state is consumed, whatever happens next.
5. Authapp redeems the code at the token URL with the client id, secret,
   and the PKCE verifier, gets the student's user token, and calls
   `GET /user` with it to learn the account's numeric id and login.
6. The identity is recorded through `api.set_user_github_identity` with
   `p_verified = true`. The same account already linked (verified or not) is
   fine, and a login change for the same id is absorbed. An account linked
   to another user is refused (`github_identity_taken`). A different account
   for a user who already has a provisioned repository under the old one is
   refused (`github_identity_locked`): staff resolve that, by design.
7. Membership, with the credentials kept apart:
   - `GET /orgs/{org}/memberships/{login}` with the **course** credential.
   - If none: `PUT /orgs/{org}/memberships/{login}` (role `member`) with the
     **course** credential, which creates a pending invitation.
   - If pending: `PATCH /user/memberships/orgs/{org}` with `state: active`
     using the **student's** token, which only the invitee can do. GitHub
     answers 200 with the membership, or 202 when the acceptance is queued;
     on a 202 the membership is re-read with the course credential, and if
     it is not yet active the student is told (`membership_not_active`) and
     clicks again in a moment.
   - An existing active membership is left as it is, role included: a
     student who was already a member but had no identity on record gets
     the identity linked and the team add, and no invitation.
   - Then, if `GITHUB_PROVISIONER_STUDENTS_TEAM_SLUG` is set,
     `PUT /orgs/{org}/teams/{team}/memberships/{login}` with the **course**
     credential. Repeating it for a member is a no-op.
8. The browser is redirected to `next` with `github_join=ok`: as a query
   parameter for the repositories page
   (`/auth/repositories?github_join=ok`), which renders it as a one-line
   notice, or in the fragment's own query for a client route
   (`/#/assignments/<slug>?github_join=ok`), which is where the Elm client
   reads it. The callback never creates a repository itself; the student
   presses *Create* on the page.

The student's token exists in one variable of the callback handler and
nowhere else: not in the session, not in the database, not in a log line,
not in a response, whatever path the handler takes. The verified identity
is what persists. `authapp/join_test.go` holds the code to that: every test
ends by grepping a recording session store and the captured log for the
token.

Every step in 7 is idempotent, so a failure part-way is retried by clicking
again: a student who was invited but whose accept failed is not invited a
second time, and one whose team add failed is not re-invited or re-accepted.
Each teammate on a team assignment authorizes for themselves; the page
tells a student when a teammate's membership is what is missing
(`team_prerequisites_incomplete`), and offers no join for someone else's
account.

## What the student sees

One GitHub screen: the App's name, the organization that owns it, what it
asks for on the student's account (the organization permission, shown by
GitHub as the ability to act on organization membership on their behalf;
nothing about their repositories), and *Authorize* / *Cancel*. If they are not signed in to GitHub, GitHub's sign-in comes first.
Then they are back on the repositories page, shown as *Connected as
`<login>`* with a *verified* badge, and press *Create*. They are never
asked to type a username.

If they arrive at the landing page without a course session (a stale tab,
say), they are sent through CAS and back to it.

## Failure markers

The callback always ends on `next`, with `github_join` in its query (the
page's, or the fragment's for a client route) telling the page what
happened. The repositories page renders each as a one-line notice; a
client page may do more:

| `github_join` | Meaning | What the page should do |
| --- | --- | --- |
| `ok` | Verified, member, on the team. | Show it; the student presses *Create*. |
| `denied` | The student clicked *Cancel* on GitHub. | Keep the `needs_org_join` state with its join link. |
| `error:authorization_failed` | GitHub reported an error other than a denial, sent no code, refused the code (expired, already used, or a redirect_uri mismatch), or refused the student's token (which is what an App not installed on the organization looks like). | Offer the join link again. |
| `error:join_app_misconfigured` | GitHub refused the join App's client id or secret. Logged as `ERROR`; an operator problem. | Tell them to contact staff. |
| `error:github_unavailable` | GitHub timed out or answered a 5xx somewhere in the flow. | Offer the join link again. |
| `error:github_rate_limited` | GitHub is rate limiting the token endpoint or the course credential. | Ask them to wait a minute. |
| `error:github_credential_rejected` | GitHub refused the **course** credential. Logged as `ERROR`; an operator problem. | Tell them to contact staff. |
| `error:github_identity_taken` | That GitHub account is linked to another course user. | Tell them to contact staff. |
| `error:github_identity_locked` | They already have a repository under a different GitHub account. | Tell them to contact staff. |
| `error:platform_unavailable` | PostgREST did not answer. | Offer to try again. |
| `error:membership_not_active` | Every call succeeded and GitHub still does not report them active in the organization or on the team. Trying again is safe. | Offer the join link again. |

The refusals in step 4 (state mismatch, replay, expiry, wrong session, no
session) are not markers: they are a 400 (or 401) page, because a callback
that matches nothing this session started is not one to act on, including
by redirecting.

## What to check when it does not work

- **The authorize screen says "redirect_uri is not associated with this
  application"**: the App's Callback URL does not match
  `https://<FQDN>/auth/github/callback`. Check the scheme and host the
  proxy forwards (`X-Forwarded-Proto`, `X-Forwarded-Host`).
- **`error:join_app_misconfigured`, and the log says
  `incorrect_client_credentials`**: the client id or secret is wrong or was
  rotated.
- **`error:authorization_failed` after the student clicked Authorize, and
  the log says GitHub refused the student's token (403) on the accept**:
  the join App is not installed on the course organization, or its
  installation lost *Organization → Members: write*. Install it (above).
  Authorization alone does not let a user token act on the organization.
- **Startup panic naming a `GITHUB_JOIN_APP_*_URL`**: plain `http` to a
  non-local host outside development. Use `https`, or set `DEVELOPMENT`
  for a local stack.
- **`error:github_credential_rejected`**: the provisioner's credential lost
  *Organization → Members: write*, or its installation was removed. This is
  the provisioner's problem, not the join App's; see github-provisioning.md.
- **The student is verified but not a member**: look at the log for the
  step that failed and have them click again; the identity is kept and the
  membership steps resume.

## For the course consumer

Once the join is enabled, the typed `github-username` assignment that
`yale-mgt-656-fall-2026/admin` used to collect logins is unnecessary: every
student's login and numeric id arrive verified through this flow, and
`api.users.github_verified_at` says so. Retire that assignment (or leave it
closed) rather than keep two sources of a login that can disagree, and stop
the consumer's own invitation step, since the student now accepts their own.
The faculty bootstrap `api.import_github_logins` remains for a roster whose
logins are known before the students arrive; a login it imported is
unverified until the student completes this flow, and the flow accepts the
same account without complaint. See yale-mgt-656-fall-2026/admin#53.
