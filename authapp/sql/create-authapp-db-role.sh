#!/bin/bash
# Create (or rotate the password of) the least-privilege role authapp uses to
# reach its session store.
#
# authapp talks to PostgREST over HTTP for everything else and had no database
# connection at all before issue #365. Sessions are the one thing PostgREST
# cannot carry: they are written on every request, belong to no course-data
# role, and must survive a container recreate.
#
# This lives here rather than in a migration because roles are cluster-wide
# while migrations are per-database, yelukerest_migrator is NOCREATEROLE
# (bin/provision-db.sh), and a password must never be committed. It is the
# same split Hydra uses; see hydra/sql/create-hydra-db.sh.
#
# Run it ONCE PER CLUSTER, as a superuser, BEFORE deploying the
# add-authapp-session-store migration -- including against any disposable test
# database's cluster, or the deploy stops with a hint pointing back here.
#
#   AUTHAPP_DB_PASS=... ./authapp/sql/create-authapp-db-role.sh
#
# It reads .env by default, so in the ordinary case there is nothing to pass:
#
#   ./authapp/sql/create-authapp-db-role.sh
#
# Connect as a superuser either by exporting the usual PG* variables, or by
# setting SUPERUSER_DATABASE_URL. Rotating the password is this script again
# with the new value, followed by restarting authapp so its AUTHAPP_DB_URL
# matches.
#
# The role is least-privilege: LOGIN and nothing else. Its only object
# privileges are the ones the migration grants on data.authapp_session, and
# that migration's verify.sql asserts it holds no others.
set -euo pipefail

if [ -f "${ENV_FILE:-.env}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${ENV_FILE:-.env}"
    set +a
fi

AUTHAPP_DB_USER="${AUTHAPP_DB_USER:-authapp}"
AUTHAPP_DB_PASS="${AUTHAPP_DB_PASS:?AUTHAPP_DB_PASS must be set}"

# The database named here is irrelevant to the result -- role attributes are
# cluster-wide -- but psql needs one to connect to.
if [ -n "${SUPERUSER_DATABASE_URL:-}" ]; then
    set -- "$SUPERUSER_DATABASE_URL"
else
    export PGHOST="${PGHOST:-${DB_DEV_HOST:-localhost}}"
    export PGPORT="${PGPORT:-${DB_PORT:-5432}}"
    export PGUSER="${PGUSER:-${SUPER_USER:?SUPER_USER or SUPERUSER_DATABASE_URL must be set}}"
    export PGPASSWORD="${PGPASSWORD:-${SUPER_USER_PASSWORD:-}}"
    set -- "--dbname=${PGDATABASE:-postgres}"
fi

psql -X -v ON_ERROR_STOP=1 -q \
    -v authapp_user="$AUTHAPP_DB_USER" \
    -v authapp_pass="$AUTHAPP_DB_PASS" \
    "$@" <<'EOSQL'
select format(
    'create role %I with login nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls password %L',
    :'authapp_user', :'authapp_pass'
) where not exists (select from pg_roles where rolname = :'authapp_user')
\gexec
-- Reruns must pick up a rotated password: authapp's AUTHAPP_DB_URL carries the
-- new value the moment Compose restarts it, so the role has to match.
select format(
    'alter role %I with login nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls password %L',
    :'authapp_user', :'authapp_pass'
) where exists (select from pg_roles where rolname = :'authapp_user')
\gexec
EOSQL

echo "authapp session-store role '${AUTHAPP_DB_USER}' is ready"
