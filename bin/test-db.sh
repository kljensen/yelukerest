#!/usr/bin/env sh
set -eu

if ! command -v pg_prove >/dev/null 2>&1; then
  echo "pg_prove is required to run database tests." >&2
  echo "Install pgTAP locally, or run this in a development image that includes pg_prove." >&2
  exit 127
fi

set -a
. ./.env
set +a

./bin/reset_db.sh

export PGPASSWORD="${SUPER_USER_PASSWORD}"

pg_prove \
  --host "${DB_TEST_HOST:-localhost}" \
  --port "${DB_TEST_PORT:-${DB_PORT}}" \
  --username "${SUPER_USER}" \
  --dbname "${DB_NAME}" \
  tests/db/*.sql
