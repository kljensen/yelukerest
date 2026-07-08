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
- `caddy` uses explicit Caddy Alpine builder/runtime tags.
- `postgrest` uses `ghcr.io/kljensen/docker-postgrest-static:14.14`, a
  checksum-verified `scratch` image built from upstream PostgREST release
  assets. The local arm64 image measured 86,556,914 bytes because upstream
  publishes a dynamic Ubuntu aarch64 binary rather than a Linux static arm64
  asset.

## Current Local Sizes

Measured on 2026-07-07 after building the REST stack and Elm test target:

| Image | MiB |
| --- | ---: |
| `yelukerest-authapp:latest` | 9.2 |
| `yelukerest-backup:latest` | 45.2 |
| `yelukerest-caddy:latest` | 105.0 |
| `yelukerest-elmclient:latest` | 72.9 |
| `yelukerest-elmclient-test:latest` | 221.6 |
| `yelukerest-postgres:18.4-pgbackrest` | 306.0 |
| `yelukerest-postgres-dev:18.4-pgtap` | 308.8 |
| `ghcr.io/kljensen/docker-postgrest-static:14.14` | 82.5 |

## Known Tradeoffs

- The production Postgres image is larger than the upstream Alpine image because
  pgBackRest must be available inside the database container for WAL archiving.
- The Elm test image carries Deno only in the `test` target; the app target does
  not include Deno or Node.
- The Caddy image is Alpine-based, but the Route53 DNS provider produces a
  larger binary and a heavy build-time Go dependency graph.
- Root REST tests still use Bun plus JavaScript test dependencies. That is
  test-only tooling, not a runtime container dependency.
