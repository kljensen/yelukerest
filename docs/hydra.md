# Ory Hydra Runbook

## Why

Ory Hydra is the OAuth 2.1 authorization server that lets MCP clients
(Claude Desktop, claude.ai, ChatGPT, self-written agents) obtain tokens
for the MCP endpoint. See `docs/adr/0001-mcp-and-oauth.md` for the
selection rationale and threat model. Hydra owns clients, codes, tokens,
Dynamic Client Registration (DCR), and PKCE; login and consent are
delegated to `authapp`'s CAS-backed session (issue #273). Hydra-issued
tokens are validated by `mcpapp` only and never reach PostgREST.

## Topology And Routing

- Container `hydra` (`oryd/hydra:v26.2.0`, digest recorded in
  `docker-compose.base.yaml` for later digest-pinning).
- Public API on port 4444, reachable only from Caddy on the internal
  compose network. Caddy routes these paths at the top level of the
  domain (see the `(hydra)` snippet in `caddy/Caddyfile`):
  `/oauth2/*` (auth, token, register, revoke, sessions, fallbacks),
  `/userinfo`, `/.well-known/openid-configuration`,
  `/.well-known/oauth-authorization-server`, `/.well-known/jwks.json`.
- Admin API on port 4445: **never published to the host, never proxied
  by Caddy**. It is reachable only from other containers on the compose
  network (breakglass below).
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
  and wget):

  ```sh
  docker compose ... exec -T elmclient \
    wget -qO- http://hydra:4445/admin/clients
  # Delete a client:
  docker compose ... exec -T elmclient \
    wget -qO- --method=DELETE http://hydra:4445/admin/clients/<client_id>
  ```

Never add a Caddy route or a host port mapping for 4445, even
temporarily.

## Client Pruning (Placeholder — Issue #272)

Claude Code registers a fresh DCR client on every connection
(anthropics/claude-code#59460), so the client table grows without bound.
A prune job (delete clients with no token activity for >30 days) plus a
doctor alert when the client count far exceeds enrollment are
implemented in issue #272. Until then, prune manually via the breakglass
admin API above.

## Upgrade Procedure

1. Read the Hydra release notes for config schema and migration
   changes. Re-check the ADR caveats register — especially
   [ory/hydra#4044](https://github.com/ory/hydra/issues/4044): Hydra's
   DCR responses include null/empty optional fields that break
   strict-parser MCP clients (mcp-remote, Cursor, TS-SDK-based). A
   response-cleaning proxy on `/oauth2/register` is tracked in issue
   #272; **verify on every upgrade whether the upstream fix (PR #4050)
   shipped** — if it did, the proxy can be deleted; if not, the proxy
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
