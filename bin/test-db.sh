#!/usr/bin/env sh
set -eu

PG_PROVE="${PG_PROVE:-pg_prove}"
PSQL_BIN="${PSQL_BIN:-psql}"

if ! command -v "$PG_PROVE" >/dev/null 2>&1; then
  echo "pg_prove is required to run database tests." >&2
  echo "Install pgTAP locally, or run this in a development image that includes pg_prove." >&2
  exit 127
fi

if ! command -v "$PSQL_BIN" >/dev/null 2>&1; then
  echo "psql is required to prepare database tests." >&2
  exit 127
fi

set -a
. ./.env
set +a

DB_TEST_HOST="${DB_TEST_HOST:-localhost}"
DB_TEST_PORT="${DB_TEST_PORT:-${DB_PORT}}"

./bin/reset_db.sh

export PGPASSWORD="${SUPER_USER_PASSWORD}"

"$PSQL_BIN" \
  --host "$DB_TEST_HOST" \
  --port "$DB_TEST_PORT" \
  --username "${SUPER_USER}" \
  --dbname "${DB_NAME}" \
  --command 'CREATE EXTENSION IF NOT EXISTS pgtap;'

"$PG_PROVE" \
  --psql-bin "$PSQL_BIN" \
  --host "$DB_TEST_HOST" \
  --port "$DB_TEST_PORT" \
  --username "${SUPER_USER}" \
  --dbname "${DB_NAME}" \
  tests/db/*.sql
