# Ory Hydra Runbook

## Why

Ory Hydra is the OAuth 2.1 authorization server that lets MCP clients
(Claude Desktop, claude.ai, ChatGPT, self-written agents) obtain tokens
for the MCP endpoint. See `docs/adr/0001-mcp-and-oauth.md` for the
selection rationale and threat model. Hydra owns clients, codes, tokens,
Dynamic Client Registration (DCR), and PKCE; login and consent are
delegated to `authapp`'s CAS-backed session (issue #273). Hydra-issued
tokens are validated by `mcpapp` only and never reach PostgREST. The
student-facing side of this — what the browser flow looks like and what
the consent page is asking — is `docs/mcp-for-students.md`.

## Topology And Routing

- Container `hydra` (`oryd/hydra:v26.2.0`, digest recorded in
  `docker-compose.base.yaml` for later digest-pinning).
- Public API on port 4444, reachable only from Caddy on the internal
  compose network. Caddy routes these paths at the top level of the
  domain (see the `(hydra)` snippet in `caddy/Caddyfile`):
  `/oauth2/*` (auth, token, register, revoke, sessions, fallbacks),
  `/userinfo`, `/.well-known/openid-configuration`,
  `/.well-known/oauth-authorization-server`, `/.well-known/jwks.json`.
- Exception: `/oauth2/register` and `/oauth2/register/{id}` (Dynamic
  Client Registration) are routed to **authapp**, which reverse-proxies
  them to Hydra's public port. authapp strips the null/empty optional
  fields from Hydra's DCR responses that break strict-parser MCP
  clients ([ory/hydra#4044](https://github.com/ory/hydra/issues/4044)),
  injects the MCP audience allowlist so token refresh works (issue
  #271 spike), and hardens registration: per-IP rate limit (10/min),
  64KB body cap, at most 10 `redirect_uris` of at most 2000 chars,
  https-only redirect URIs except `http://localhost` /
  `http://127.0.0.1` loopback. See `authapp/register.go`; remove the
  proxy when the upstream fix ships (issue #272).
- Admin API on port 4445: **never published to the host, never proxied
  by Caddy**. It is reachable only from other containers on the compose
  network (breakglass below). authapp calls it for the delegated
  login/consent handlers (below) using `HYDRA_ADMIN_URL`, which
  defaults to `http://hydra:4445`; set it only if Hydra's admin
  listener moves.
- The OAuth issuer is the bare domain root (`https://$FQDN`, or
  `https://localhost` in dev), not a path prefix. Rationale is
  documented at the top of `hydra/hydra.yml`: RFC 8414 and OIDC
  discovery disagree about where metadata lives for issuers with a path
  component, real MCP clients resolve that inconsistently, and Hydra
  serves its well-known documents only at the root of its listener. A
  root issuer sidesteps all of it, and none of Hydra's paths collide
  with existing routes.

## Configuration Knobs

Static configuration lives in `hydra/hydra.yml` (mounted read-only).
Deployment-specific values are environment variables in compose (Hydra
maps `urls.self.issuer` to `URLS_SELF_ISSUER`, and so on):

| Env var | Meaning |
| --- | --- |
| `DSN` | Storage. `memory` in dev; Postgres URL in prod. |
| `SECRETS_SYSTEM` | Encrypts data at rest; from `HYDRA_SECRETS_SYSTEM` in `.env`. |
| `URLS_SELF_ISSUER` | Token/discovery issuer. `https://$FQDN` (dev: `https://localhost`). |
| `URLS_LOGIN`, `URLS_CONSENT` | authapp's OAuth login/consent handlers under `/auth/oauth/*`. |
| `WEBFINGER_OIDC_DISCOVERY_CLIENT_REGISTRATION_URL` | Must be set or discovery omits `registration_endpoint` even with DCR enabled. |

Key settings in `hydra.yml` (see the file for full comments):

- `strategies.access_token: jwt` — mcpapp validates tokens locally via JWKS.
- `oauth2.allowed_top_level_claims: [role, user_id, netid, scopes]`.
- `oauth2.pkce.enforced_for_public_clients: true` (OAuth 2.1).
- `oidc.dynamic_client_registration.enabled: true`, default scope
  `openid offline_access`.
- `ttl.access_token: 1h`, `ttl.refresh_token: 720h` (30 days).
- `oauth2.grant.refresh_token.rotation_grace_period: 30s`.

authapp reads these variables for the OAuth and DCR handlers:

| Env var | Meaning |
| --- | --- |
| `HYDRA_ADMIN_URL` | Hydra's admin API. Default `http://hydra:4445`; override only if the admin listener moves. Never route it through Caddy. |
| `MCP_RESOURCE_URL` | Canonical MCP resource, granted as the access-token audience and injected into client allowlists. Falls back to `https://$FQDN/mcp`. Must match mcpapp's expected audience exactly. |
| `HYDRA_PUBLIC_INTERNAL_URL` | Where the DCR proxy forwards `/oauth2/register`. Default `http://hydra:4444`. |
| `MCPAPP_JWT` | Service credential for `/auth/mcp-token`. See below. |

### mcpapp Configuration

mcpapp is the OAuth *resource server*; both of the following are already wired in
`docker-compose.base.yaml`, but they are the two that break silently when a
`.env` is stale:

| Env var | Meaning |
| --- | --- |
| `MCPAPP_JWT` | `role=app`, `app_name=mcpapp` service credential, used only to call `api.issue_user_jwt_for_mcp` when exchanging a verified OAuth token for an internal course credential. Mint with `./bin/jwt.sh '{"role":"app","app_name":"mcpapp"}'`. **Unset is not fatal**: mcpapp starts, OAuth tokens still verify, and then every OAuth caller's first tool call fails. Startup logs `WARNING: MCPAPP_JWT is not set`. The same value belongs in authapp's environment, where its absence makes `/auth/mcp-token` return `503`. |
| `HYDRA_PUBLIC_INTERNAL_URL` | Base URL for the JWKS fetch, default `http://hydra:4444`. Keeps key retrieval on the internal compose network so it never traverses Caddy's TLS — in dev that is a certificate the mcpapp container does not trust, so pointing this at the public URL breaks every token validation with a TLS error. |

The rest: `MCP_RESOURCE_URL` (or `FQDN`) fixes the audience mcpapp demands;
`HYDRA_PUBLIC_URL` is the authorization server advertised in the RFC 9728
protected-resource metadata, and leaving it empty disables the OAuth path
entirely (phase 0 bearer tokens only); `HYDRA_ISSUER` and `HYDRA_JWKS_URL`
override the two values derived from it; `JWT_MCP_AUDIENCE` (default
`yelukerest-mcp`) is the audience of the phase 0 bearer tokens.

## Delegated Login And Consent (Issue #273)

Hydra sends the browser to `urls.login` / `urls.consent` with an opaque
challenge; `authapp/oauth.go` resolves each challenge against the admin
API, decides, and PUTs an accept or reject back.

**`GET /auth/oauth/login`** — fetches the login request; if Hydra says
`skip`, it accepts immediately with the subject Hydra already holds.
Otherwise it needs an scs session: with one, it accepts with
`subject = <the session's netid>`; without one, it redirects into the
existing CAS flow (`/auth/login?next=…`) with a `next` rebuilt
server-side from the handler's own path plus the validated challenge, so
the return target is always an internal path.

**`GET /auth/oauth/consent`** — renders a JS-free, unstyled-by-CSP form
(the stylesheet is served same-origin from `/auth/oauth/consent.css`
because Caddy's CSP sets `style-src 'self'`, which forbids inline
`<style>`). It leads with the client's **registered redirect origins and
`client_id`** — `client_name` is chosen by whoever registered the client,
so it is shown labeled self-reported. Read scopes are checked by default
and write scopes are not (ADR 0001 default-deny for writes), and the page
names the data categories from the ADR's FERPA policy note. A one-time
CSRF token bound to (session, challenge) lives in the session.

**`POST /auth/oauth/consent`** — verifies the CSRF token, then re-fetches
the consent request from Hydra: subject, client, and the grantable scope
set never come from the form. It grants
`intersection(requested, approved)`, sets
`grant_access_token_audience` to the MCP resource URL, attaches
`session.access_token` claims `{netid, user_id, role, scopes}` (the four
names in `allowed_top_level_claims`; `scopes` is space-delimited to match
the internal MCP JWT), and sets `remember: false`. Anything other than
the Allow button rejects with `access_denied`.

Two details that are easy to get wrong:

- **Audience allowlist.** Before accepting, the handler ensures the
  client's `audience` metadata contains the MCP resource, patching it via
  `PATCH /admin/clients/{id}` when it does not. The DCR proxy already
  injects it at registration, so this only fires for clients registered
  before that landed — but without it Hydra's *refresh*-time re-validation
  fails with "Requested audience … has not been whitelisted" (issue #271
  spike, finding 2). Verified live: a client whose allowlist was emptied
  had it repaired at consent time and refreshed successfully.
- **Challenge size.** With `DSN=memory` Hydra encodes the whole
  authorization request into the challenge — a measured `login_challenge`
  was 1168 characters of base64url with `==` padding, not a short id. Any
  validation of challenges must allow for that (authapp caps at 8 KB).

Rate limits are 60/min per client IP across the three handlers; all
responses are `no-store` with `X-Frame-Options: DENY` and a tight CSP.
Challenges, verifiers, codes, and tokens are never logged — the mock CAS
handler logs the service URL without its query for the same reason.

## Dev Loop

`./bin/dev.sh up` starts Hydra with `DSN=memory`.

Memory-mode caveats:

- **Everything is lost on restart**: registered clients, consent
  sessions, and the signing JWKS. Connected MCP clients must re-register
  and re-authorize after every `dev.sh up`/restart, and previously
  issued JWT access tokens fail JWKS validation.
- Memory mode is SQLite-in-memory and **masks locking/concurrency
  races**. Concurrency-sensitive tests (refresh-token reuse detection,
  restart survival) must run against Postgres-backed Hydra: the dev db
  container creates a `hydra` database on first boot
  (`hydra/sql/create-hydra-db.sh`), so point `DSN` at
  `postgres://hydra:$HYDRA_DB_PASS@db:5432/hydra?sslmode=disable`, run
  the migrate job, and restart Hydra. (If your dev db volume predates
  this, `./bin/reset_db.sh` recreates it.)

## End-To-End Test Suite (Issue #275)

`bun run test_oauth` drives the whole OAuth + MCP stack the way a third-party
MCP client does: dynamic client registration through the cleaning proxy, an
authorization-code + PKCE flow that logs in through the mock CAS server and
posts the JS-free consent form, a token exchange, then JSON-RPC calls against
`/mcp`. Nothing is stubbed. It needs a running stack:

```
./bin/dev.sh up
bun run test_oauth
```

`bun run test` runs it between the database and REST suites.

Files, all under `tests/oauth/`:

| File | Covers |
| --- | --- |
| `helpers.js` | the flow driver, the MCP client, and the Hydra admin/psql escape hatches |
| `happy-path.js` | full flow as student, TA and faculty; tool inventory; RLS boundaries |
| `token-lifecycle.js` | refresh rotation, reuse detection, consent revocation |
| `security-negatives.js` | audience, signature, expiry, PKCE, code replay, redirect matching, consent CSRF and form tampering |
| `client-quirks.js` | DCR response shape, loopback callbacks, discovery and RFC 9728 metadata |
| `write-path.js` | preview and submit, and the write-scope boundary |
| `zz-log-scan.js` | no credential or student content in service logs |

Two things the suite needs that a public client cannot do are reached through
`docker compose exec`: Hydra's admin API (port 4445 is never proxied and never
published, so `helpers.js` speaks raw HTTP to it over `nc` inside the db
container) and `psql`, for checking that a refused write really wrote nothing.

Behaviours the suite deliberately pins, so that changing them is a conscious
decision rather than a silent one:

- **Refresh reuse has a 30s grace window.** `oauth2.grant.refresh_token.rotation_grace_period`
  lets one retried refresh through; only a replay after the window is treated
  as theft, and it then invalidates the whole family. The reuse test sleeps out
  the window, which is why that file takes ~40s.
- **Revocation is bounded by the access-token TTL.** Access tokens are JWTs
  that mcpapp validates locally, so revoking consent kills the refresh token
  immediately but leaves an issued access token working until it expires.
- **Loopback redirect URIs match loosely on the port and exactly on the host.**
  `http://127.0.0.1:ANY/callback` is accepted for a client registered on
  127.0.0.1 (RFC 8252, for native clients that bind an ephemeral port), but
  `localhost` and `127.0.0.1` are different hosts and are not interchangeable.
- **PKCE is enforced after login, not before it.** An authorization request
  with no `code_challenge` (or with `plain`) is accepted at `/oauth2/auth` and
  refused at the point a code would be issued, so the user authenticates before
  the downgrade is caught. No code is ever minted.
- **mcpapp's scope gate is coarse.** `authorizeScope` distinguishes read from
  write only; any of `course:read`/`grades:read`/`submissions:read` satisfies
  "read". A token the user narrowed at the consent screen to exclude
  `grades:read` still reaches `get_my_grades`. The consent screen offers
  granularity the resource server does not enforce.
- **Caddy's debug log records authorization codes.** `caddy/Caddyfile` enables
  the global `debug` option and is mounted from `docker-compose.base.yaml`, so
  this applies in production too. Debug "upstream roundtrip" entries include
  upstream response headers verbatim, and the authorization endpoint's redirect
  carries `?code=ory_ac_...` in `Location`. Authorization headers are redacted;
  `Location` is not. Codes are single-use, short-lived and PKCE-bound, so a log
  reader without the verifier cannot redeem one, but they should not be in the
  logs.

Rate limits shape the runtime. authapp allows 60 requests/minute to the OAuth
login and consent handlers and 10 client registrations/minute, and the suite
walks the flow about thirty times, so `helpers.js` paces itself under those
limits. A full run takes roughly two minutes; back-to-back runs are slower
while the server's sliding window drains.

Cleanup is automatic and the suite is re-runnable: every canary client this run
registers is deleted when the run ends (`tests/oauth-setup.js`), any client
left behind by an interrupted run is swept before the first registration, and
the write-path tests reset the database on both sides.

## Production Deployment

One-time bootstrap, in order:

1. Set `HYDRA_SECRETS_SYSTEM`, `HYDRA_DB_USER`, `HYDRA_DB_PASS` in
   `.env` (generate with `openssl rand -hex 32`).
2. Create the dedicated database and least-privilege role. The prod db
   volume already exists, so initdb scripts do not run; run the helper
   manually once:

   ```sh
   # Export the credentials from .env first — the shell expands the
   # -e values before docker compose ever reads .env:
   set -a; . ./.env; set +a
   docker compose -f docker-compose.base.yaml -f docker-compose.prod.yaml \
     exec -e HYDRA_DB_USER="$HYDRA_DB_USER" -e HYDRA_DB_PASS="$HYDRA_DB_PASS" \
     db bash /opt/hydra/create-hydra-db.sh
   ```

   Rerunning the helper is safe: it updates the role password in place,
   so it is also the procedure for rotating `HYDRA_DB_PASS`.

   The `hydra` role is LOGIN-only, owns only the `hydra` database, and
   has no object privileges in the application database (it retains only
   the default PUBLIC CONNECT grant every role has there).
3. `./bin/prod.sh up -d` — the one-shot `hydra-migrate` service runs
   `hydra migrate sql up` and the `hydra` service starts only after the
   migration completes successfully.
4. `./bin/doctor.sh` — checks `/health/ready`, both discovery documents,
   issuer consistency, DCR advertisement, and PKCE S256.

## Secrets: SECRETS_SYSTEM Rotation

`SECRETS_SYSTEM` encrypts Hydra's database rows (e.g. JWKs). Rotation
uses a comma-separated list; the **first** value encrypts new data,
later values are still accepted for decryption:

1. `HYDRA_SECRETS_SYSTEM=<new>,<old>` in `.env`; recreate the container
   (`./bin/prod.sh up -d hydra`).
2. Leave both in place until all rows written under the old secret have
   been rewritten or expired (refresh TTL is 30 days, so a full cycle is
   ~30 days unless you force re-encryption).
3. Remove `<old>`.

Losing all values of `SECRETS_SYSTEM` makes encrypted rows (including
signing keys) unreadable; treat it like a database credential and keep
it in the same secret store as `.env`.

## Signing Key (JWKS) Rotation

Hydra creates `hydra.openid.id-token` and `hydra.jwt.access-token` key
sets automatically. To rotate, create a new key in the set via the admin
API (breakglass below); new tokens use the new key while the JWKS
endpoint continues to publish the old public key for validation until
you delete it. Rotate after any suspected key exposure and at least once
per semester.

## Backups And Restore Drill

- **Prod (pgbackrest)**: pgbackrest archives the entire Postgres
  cluster, so the `hydra` database is included automatically — no
  configuration change needed. A cluster restore restores Hydra state
  too.
- **Logical dumps**: `bin/dumpdb.sh` now also writes `hydra.dump`
  (custom format) whenever the `hydra` database exists.
- **Restore drill** (logical):

  ```sh
  # 1. Recreate role + empty database if needed
  docker compose ... exec ... db bash /opt/hydra/create-hydra-db.sh
  # 2. Restore
  pg_restore -h <host> -p <port> -U $SUPER_USER -d hydra --no-owner \
      --role=hydra hydra.dump
  # 3. Bring schema to the running version, then start Hydra
  docker compose ... up hydra-migrate && docker compose ... up -d hydra
  # 4. Verify
  ./bin/doctor.sh
  ```

- Worst case (dump lost, secrets intact): drop and recreate the `hydra`
  database and re-run the migrate job. All clients and grants are lost;
  MCP clients re-register via DCR and users re-consent — disruptive but
  self-healing.

## Breakglass: Admin Access

The admin API is intentionally unreachable from the host. Two ways in:

- **Hydra CLI in the container** (image has no shell, but the binary is
  on PATH):

  ```sh
  docker compose -f docker-compose.base.yaml -f docker-compose.prod.yaml \
    exec hydra hydra list oauth2-clients --endpoint http://127.0.0.1:4445
  ```

- **Admin REST API from a neighbor container** (elmclient has a shell
  and busybox wget — GET/POST only; use the hydra CLI above for
  DELETE):

  ```sh
  docker compose ... exec -T elmclient \
    wget -qO- http://hydra:4445/admin/clients
  # Delete a client (busybox wget cannot send DELETE):
  docker compose ... exec -T hydra \
    hydra delete oauth2-client <client_id> --endpoint http://127.0.0.1:4445
  ```

Never add a Caddy route or a host port mapping for 4445, even
temporarily.

## Client Pruning (Issue #272)

Claude Code registers a fresh DCR client on every connection
(anthropics/claude-code#59460), so the client table grows without
bound. Two tools keep it in check:

- **Alert**: `./bin/doctor.sh` counts registered clients via the admin
  API and warns when the count exceeds `HYDRA_CLIENT_COUNT_WARN`
  (default 500 — far above any realistic enrollment).
- **Prune**: `./bin/prune-hydra-clients.sh` deletes stale clients.

The prune script deletes clients that are **both** older than N days
(`--days`, default 30 — `created_at` and `updated_at`) **and** not
referenced by any active consent session (checked via the admin REST
API per subject; subjects are enumerated from the app `user` table, so
the db container must be up). It is conservative:

- **Dry run by default** — prints the candidates; `--yes` deletes.
- Only public clients (`token_endpoint_auth_method: "none"`, the DCR
  churn population) are considered unless `--include-confidential` is
  given, so manually registered confidential clients are never touched
  by default.
- If subjects or consent sessions cannot be enumerated, it aborts
  instead of pruning blind.

```sh
# See what would be deleted (dev: DEVELOPMENT=1 selects dev compose files)
./bin/prune-hydra-clients.sh
# Delete clients idle more than 45 days
./bin/prune-hydra-clients.sh --days 45 --yes
```

Keep `--days` at or above the refresh-token TTL (30 days,
`ttl.refresh_token` in `hydra/hydra.yml`): consent-session listing is
the activity signal, and a client whose consent was not remembered
could in principle still hold refresh tokens younger than the TTL.
Run it monthly (manually or from cron on the host); doctor's warning
is the reminder that it has not been run.

## Upgrade Procedure

1. Read the Hydra release notes for config schema and migration
   changes. Re-check the ADR caveats register — especially
   [ory/hydra#4044](https://github.com/ory/hydra/issues/4044): Hydra's
   DCR responses include null/empty optional fields that break
   strict-parser MCP clients (mcp-remote, Cursor, TS-SDK-based). The
   response-cleaning proxy on `/oauth2/register` lives in authapp
   (`authapp/register.go`, issue #272); **verify on every upgrade
   whether the upstream fix (PR #4050) shipped** — if it did, the
   cleaning code can be deleted (keep the hardening); if not, the proxy
   must keep working against the new response shape.
2. Take a backup (`bin/dumpdb.sh` or a pgbackrest backup).
3. Bump the image tag (and recorded digest) in
   `docker-compose.base.yaml` for both `hydra` and `hydra-migrate`.
4. `docker compose ... up hydra-migrate` (migrations are
   forward-only; that is why step 2 is not optional), then
   `docker compose ... up -d hydra`.
5. `./bin/doctor.sh`, then a real-client smoke test: DCR registration
   plus an authorization-code redirect to `/auth/oauth/login`.

## Doctor Checks

`./bin/doctor.sh` (function `check_hydra`) verifies, when the stack is
up: `/health/ready` on the internal network; both discovery documents
fetchable through Caddy; issuer consistency with the expected public
URL; `registration_endpoint` advertised (DCR on); PKCE S256 advertised.
Set `HYDRA_CHECK_URL` to override the public base URL it probes.

`check_hydra_client_count` additionally counts registered OAuth
clients via the admin API and warns above `HYDRA_CLIENT_COUNT_WARN`
(default 500); see Client Pruning above.

## Audit Trail: MCP Token Mints

Every internal MCP credential — minted by `/auth/mcp-token` for a bearer-token
client, or by mcpapp's token exchange for an OAuth client — appends a row to
`data.mcp_jwt_mint_event` **in the same transaction that signs the token**. There
is no path that mints without recording. Two faculty-only views sit over it
(`db/src/api/yeluke/mcp_jwt.sql`; row access is enforced by RLS on the underlying
table, and only `faculty` holds SELECT):

- `api.mcp_jwt_mint_events` — the raw history: `user_id`, `netid`, `user_role`,
  granted `scopes`, the token's `jti`, the `caller_app_name` of the service
  credential that asked (`mcpapp`), the `external_issuer`/`external_sub`/
  `external_jti`/`external_client_id` of the OAuth token exchanged when there was
  one, and `created_at`. Phase 0 mints record
  `client_id = authapp:/auth/mcp-token` and no external subject.
- `api.mcp_jwt_mint_anomalies` — the alarm from the ADR threat model: one caller
  credential minting for **more than 10 distinct subjects in a sliding 10-minute
  window**, which is the signature of a stolen minting credential rather than
  normal per-student traffic. Empty is the healthy state. Each row reports
  `caller_app_name`, `window_start`, `window_end`, `distinct_subjects`, and
  `mint_count`.

Read them through PostgREST with a faculty token
(`./bin/jwt.sh '{"user_id":1,"role":"faculty"}'`):

```sh
# Anything anomalous? Empty output is good.
curl -sS -H "Authorization: Bearer $YELUKEREST_CLIENT_JWT" \
  "https://$FQDN/rest/mcp_jwt_mint_anomalies"

# Recent mints, newest first.
curl -sS -H "Authorization: Bearer $YELUKEREST_CLIENT_JWT" \
  "https://$FQDN/rest/mcp_jwt_mint_events?order=created_at.desc&limit=50"

# Everything minted for one student today.
curl -sS -H "Authorization: Bearer $YELUKEREST_CLIENT_JWT" \
  "https://$FQDN/rest/mcp_jwt_mint_events?netid=eq.abc12&created_at=gte.2026-08-05"
```

Or directly in SQL via `./bin/pg_connect.sh`:

```sql
select caller_app_name, window_start, distinct_subjects, mint_count
  from api.mcp_jwt_mint_anomalies order by window_end desc limit 20;
```

Check the anomalies view when rotating `MCPAPP_JWT`, after any suspected
credential exposure, and as part of the start-of-semester caveats review. A
non-empty result means revoking `MCPAPP_JWT` (mint a new one, update both authapp
and mcpapp, restart) — the tokens it already produced expire on their own within
ten minutes.
