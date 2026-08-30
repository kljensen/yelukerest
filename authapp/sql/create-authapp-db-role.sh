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
# that migration's verify.sql asserts -- by comparing against the exact
# intended privilege set, not by checking the needed ones are present -- that
# it holds no others and none of the attributes set below have drifted.
set -euo pipefail

if [ -f "${ENV_FILE:-.env}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${ENV_FILE:-.env}"
    set +a
fi

# The role name is fixed, deliberately, and is not read from the environment.
# The migration that grants it anything spells "authapp" into its GRANT
# statements and its verify.sql, and a migration is per-database with nowhere
# to take a parameter from, so a configurable name could only ever produce a
# login that holds no grants at all. Everything that names the role -- this
# script, docker-compose.base.yaml, the migration -- says "authapp" literally
# for that reason.
AUTHAPP_ROLE=authapp

# AUTHAPP_DB_USER used to be an override, and it never worked for the reason
# above. Refusing it is louder than ignoring it, for anyone still carrying the
# setting in a .env written when it looked supported.
if [ -n "${AUTHAPP_DB_USER:-}" ] && [ "$AUTHAPP_DB_USER" != "$AUTHAPP_ROLE" ]; then
    echo "AUTHAPP_DB_USER is no longer supported: the role name is fixed at '${AUTHAPP_ROLE}'." >&2
    echo "Remove it from your environment or .env." >&2
    exit 1
fi

AUTHAPP_DB_PASS="${AUTHAPP_DB_PASS:?AUTHAPP_DB_PASS must be set}"

# The password ends up inside AUTHAPP_DB_URL, which docker-compose.base.yaml
# builds by string interpolation and cannot percent-encode. A password holding
# any of @ : / ? # % would silently reshape that URL -- an @ turns the rest of
# the password into a hostname -- so it is refused here, at the one place a
# password is set, rather than becoming a connection failure nobody can read.
# Generate one with `openssl rand -hex 32`, which is what the rest of this
# system's secrets use and is URL-safe by construction.
case "$AUTHAPP_DB_PASS" in
    *[!A-Za-z0-9._~-]*)
        echo "AUTHAPP_DB_PASS must use only A-Z a-z 0-9 . _ ~ - so it survives" >&2
        echo "interpolation into AUTHAPP_DB_URL. Generate one with: openssl rand -hex 32" >&2
        exit 1
        ;;
esac

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
    -v authapp_user="$AUTHAPP_ROLE" \
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

echo "authapp session-store role '${AUTHAPP_ROLE}' is ready"
