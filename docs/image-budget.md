# Container Image Budget

The active production/runtime path should stay on Alpine, scratch, static
binaries, or similarly small images where practical. Re-run the local report
after container changes:

```sh
bun run image_sizes
```

The script reports local image sizes in bytes and MiB and marks missing images
without failing. Build the relevant stack first when comparing changes, for
example:

```sh
docker compose -f docker-compose.base.yaml -f docker-compose.prod.yaml build
docker compose -f docker-compose.base.yaml -f docker-compose.dev.yaml build elmclient-test
```

## Current Shape

- `authapp` builds a static Go binary and runs from `scratch`.
- `elmclient` builds from an Alpine image with static Elm tooling copied from
  `ghcr.io/kljensen/docker-elm-dev-static:0.19.2`.
- `elmclient-test` stays Alpine-based and uses pinned Deno 1.x instead of Node
  for `elm-test-rs --deno`.
- `backup` runs on Alpine with pgBackRest and PostgreSQL client tools.
- `db` uses PostgreSQL 18 Alpine and adds pgBackRest so production WAL
  `archive_command` can push to the same S3-compatible repository as backups.
- `caddy` comes from `ghcr.io/kljensen/docker-caddy-dns-static:2.11.4`, a
  scratch runtime with a static Caddy binary and Route53/Cloudflare DNS
  providers.
- `postgrest` uses `ghcr.io/kljensen/docker-postgrest-static:14.14`, a
  checksum-verified `scratch` image built from upstream PostgREST release
  assets. The local arm64 image measured 86,556,914 bytes because upstream
  publishes a dynamic Ubuntu aarch64 binary rather than a Linux static arm64
  asset.

## Current Local Sizes

Measured on 2026-07-08 after building the REST stack and Elm test target:

| Image | MiB |
| --- | ---: |
| `yelukerest-authapp:latest` | 9.2 |
| `yelukerest-backup:latest` | 45.2 |
| `yelukerest-caddy:latest` | 47.8 |
| `yelukerest-elmclient:latest` | 72.9 |
| `yelukerest-elmclient-test:latest` | 221.6 |
| `yelukerest-postgres:18.4-pgbackrest` | 306.0 |
| `yelukerest-postgres-dev:18.4-pgtap` | 308.8 |
| `ghcr.io/kljensen/docker-postgrest-static:14.14` | 82.5 |
| **Total tracked current set** | **1094.0** |

The current production-ish runtime subset, excluding `elmclient-test` and
`postgres-dev`, is 563.6 MiB.

## Pre-modernization Baseline

For comparison, the pre-modernization stack was measured from commit
`843c33f` (`Add codeframe`), before the July 2026 image cleanup work removed
Redis, RabbitMQ, SSE, the AMQP bridge, and codeframe, and before the Elm,
PostgREST, PostgreSQL, backup, and Caddy image changes.

| Baseline image | MiB |
| --- | ---: |
| `yelukerest-baseline-authapp:latest` | 8.4 |
| `yelukerest-baseline-backup:latest` | 160.0 |
| `yelukerest-baseline-caddy:latest` | 86.3 |
| `yelukerest-baseline-elmclient:latest` | 1003.8 |
| `yelukerest-baseline-sse:latest` | 8.7 |
| `yelukerest-baseline-pg_amqp_bridge:latest` | 96.8 |
| `redis:6.0.9-alpine` | 30.2 |
| `rabbitmq:3.8.3` | 137.0 |
| `postgrest/postgrest:v9.0.1` | 322.2 |
| `postgres:14.4-alpine3.16` | 198.0 |
| `ghcr.io/kljensen/codeframe-docker:0.2.0` | 185.0 |
| **Total pre-modernization set** | **2236.5** |

The current tracked set is 1142.5 MiB smaller than that baseline, a 51.1%
reduction. The current production-ish runtime subset is 1672.9 MiB smaller, a
74.8% reduction.

The old AMQP bridge image cannot be rebuilt exactly today because its Rust
dependency graph was not locked and now requires a newer Cargo than the pinned
`rust:1.80.1-slim-bookworm` builder. The baseline value above keeps the old
Debian Bookworm slim runtime stage and uses a current `rust:slim-bookworm`
builder only to recover a realistic runtime image size for the removed service.

## Known Tradeoffs

- The production Postgres image is larger than the upstream Alpine image because
  pgBackRest must be available inside the database container for WAL archiving.
- The Elm test image carries Deno only in the `test` target; the app target does
  not include Deno or Node.
- The Caddy runtime is scratch/static. Its build still has a heavier Go module
  graph because DNS providers are compiled into the binary.
- Root REST tests still use Bun plus JavaScript test dependencies. That is
  test-only tooling, not a runtime container dependency.
