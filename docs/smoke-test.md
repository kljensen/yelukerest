# Local Smoke Test

## Research Notes

- Docker Compose starts services in dependency order, but does not wait for a
  container to be ready unless healthchecks and `service_healthy` conditions are
  configured. The smoke test therefore checks the running stack externally
  instead of treating `docker compose up` as proof of readiness. Source:
  <https://docs.docker.com/compose/how-tos/startup-order/>.
- PostgREST 14 has `/live` and `/ready` endpoints on its optional admin server,
  but this stack does not currently expose an admin server. The smoke test uses
  the public Caddy path to PostgREST instead. Source:
  <https://docs.postgrest.org/en/v14/references/admin_server.html>.
- Caddy supports active and passive upstream health checks, but issue #227 asks
  for an operator command that verifies the deployed surface. The first version
  is a script that targets an already-running stack. Source:
  <https://caddyserver.com/docs/caddyfile/directives/reverse_proxy>.
- GitHub issue search found older overlapping issue #116 and related public
  surface issues #217, #158, and #181. Those are broader than this smoke test:
  this command checks current behavior without solving Swagger completeness,
  HTTP header hardening, or old nginx guidance.

## Usage

Start the stack separately, then run:

```sh
./bin/smoke.sh
```

The script defaults to the development compose files and `https://localhost`.
It does not start containers or mutate data. For localhost development targets,
the script allows Caddy's internal TLS certificate. For non-localhost targets,
TLS certificates are verified by default.

For a production compose target:

```sh
YELUKEREST_SMOKE_COMPOSE_ENV_FILE=docker-compose.prod.yaml \
YELUKEREST_SMOKE_BASE_URL=https://www.example.edu \
YELUKEREST_SMOKE_HTTP_BASE_URL=http://www.example.edu \
./bin/smoke.sh
```

Useful overrides:

- `YELUKEREST_SMOKE_BASE_URL`: HTTPS base URL to check.
- `YELUKEREST_SMOKE_HTTP_BASE_URL`: HTTP base URL used for the redirect check.
- `YELUKEREST_SMOKE_COMPOSE_BASE_FILE`: base compose file, normally
  `docker-compose.base.yaml`.
- `YELUKEREST_SMOKE_COMPOSE_ENV_FILE`: environment compose file, normally
  `docker-compose.dev.yaml` or `docker-compose.prod.yaml`.
- `YELUKEREST_SMOKE_COMPOSE_EXTRA_FILE`: optional third compose file for local
  overrides.
- `YELUKEREST_SMOKE_SERVICES`: space-separated service names to inspect,
  defaulting to `db postgrest authapp caddy`.
- `YELUKEREST_SMOKE_SKIP_HTTP_REDIRECT`: set to any non-empty value to skip the
  plain HTTP redirect check.
- `YELUKEREST_SMOKE_INSECURE_TLS`: set to `1` to allow an untrusted TLS
  certificate, or `0` to force verification. When unset, this defaults to `1`
  only for localhost-style development URLs.

## Checks

The command verifies:

- expected compose services have running containers;
- Postgres accepts connections inside the `db` container;
- plain HTTP redirects to HTTPS;
- `/` serves the Elm shell through Caddy;
- `/openapi/` serves the static Swagger UI files through Caddy;
- `/rest/` returns PostgREST OpenAPI JSON through Caddy;
- `/rest/meetings?select=slug&limit=1` returns anonymous DB-backed JSON;
- `/auth/login` redirects into CAS validation through Caddy and authapp;
- `/auth/me` returns the expected unauthenticated `401 Unauthorized` response
  through Caddy and authapp.

## Scope

Use `./bin/smoke.sh` to answer whether a running stack is basically wired
through the public proxy. Use pgTAP and REST tests for database invariants,
row-level security, and API behavior. Use Elm tests for frontend pure logic.
