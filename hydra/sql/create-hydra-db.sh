#!/bin/bash
# Create the dedicated Ory Hydra database and least-privilege role.
#
# Dev/test: mounted into the postgres container's
# /docker-entrypoint-initdb.d (see docker-compose.dev.yaml) so it runs
# once on first boot, after db/src/init.sql. It deliberately lives
# outside db/src so the application schema tree stays untouched
# (issue #270).
#
# Production: the prod database volume already exists, so initdb.d
# scripts never run there. The prod compose mounts this script at
# /opt/hydra/create-hydra-db.sh; run it manually once instead:
#
#   docker compose -f docker-compose.base.yaml -f docker-compose.prod.yaml \
#     exec -e HYDRA_DB_USER="$HYDRA_DB_USER" -e HYDRA_DB_PASS="$HYDRA_DB_PASS" \
#     db bash /opt/hydra/create-hydra-db.sh
#
# ...or follow the equivalent psql steps in docs/hydra.md.
#
# The role is least-privilege: LOGIN only, no superuser/createdb/
# createrole, and it owns only the hydra database, where Hydra's
# migrations create its own tables. It has no object privileges in the
# application database (like any role it retains the default PUBLIC
# CONNECT grant there, but can read/write nothing).
set -euo pipefail

HYDRA_DB_NAME="${HYDRA_DB_NAME:-hydra}"
HYDRA_DB_USER="${HYDRA_DB_USER:-hydra}"
HYDRA_DB_PASS="${HYDRA_DB_PASS:?HYDRA_DB_PASS must be set}"
PSQL_USER="${POSTGRES_USER:-${SUPER_USER:?POSTGRES_USER or SUPER_USER must be set}}"

psql -v ON_ERROR_STOP=1 \
    -v hydra_db="$HYDRA_DB_NAME" \
    -v hydra_user="$HYDRA_DB_USER" \
    -v hydra_pass="$HYDRA_DB_PASS" \
    --username "$PSQL_USER" --dbname postgres <<'EOSQL'
select format(
    'create role %I with login nosuperuser nocreatedb nocreaterole noinherit password %L',
    :'hydra_user', :'hydra_pass'
) where not exists (select from pg_roles where rolname = :'hydra_user')
\gexec
-- Reruns must pick up a rotated password: Compose uses the new value in
-- the DSN immediately, so the role has to match.
select format(
    'alter role %I with login nosuperuser nocreatedb nocreaterole noinherit password %L',
    :'hydra_user', :'hydra_pass'
) where exists (select from pg_roles where rolname = :'hydra_user')
\gexec
select format('create database %I owner %I', :'hydra_db', :'hydra_user')
where not exists (select from pg_database where datname = :'hydra_db')
\gexec
-- Only the hydra role (and superusers) may connect to the hydra database.
select format('revoke all on database %I from public', :'hydra_db')
\gexec
EOSQL

echo "hydra database '${HYDRA_DB_NAME}' and role '${HYDRA_DB_USER}' are ready"
