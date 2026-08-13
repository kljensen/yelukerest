#!/usr/bin/env sh
# Write or rotate the runtime JWT secret after Zapadka has deployed the schema.
set -eu

if [ -f "${ENV_FILE:-.env}" ]; then
  set -a
  . "${ENV_FILE:-.env}"
  set +a
fi

: "${DB_NAME:?DB_NAME is required}"
: "${JWT_SECRET:?JWT_SECRET is required}"
: "${YELUKEREST_MIGRATOR_ROLE:=yelukerest_migrator}"
: "${YELUKEREST_MIGRATOR_PASSWORD:?YELUKEREST_MIGRATOR_PASSWORD is required}"

if [ "$YELUKEREST_MIGRATOR_ROLE" != 'yelukerest_migrator' ]; then
  echo 'YELUKEREST_MIGRATOR_ROLE must be yelukerest_migrator because immutable migrations name that owner.' >&2
  exit 1
fi

if [ "${#JWT_SECRET}" -lt 32 ]; then
  echo 'JWT_SECRET must be at least 32 characters.' >&2
  exit 1
fi

export PGUSER="$YELUKEREST_MIGRATOR_ROLE"
export PGPASSWORD="$YELUKEREST_MIGRATOR_PASSWORD"
export PGDATABASE="$DB_NAME"
export PGHOST="${PGHOST:-${DB_DEV_HOST:-localhost}}"
export PGPORT="${PGPORT:-${DB_PORT:-5432}}"
export JWT_SECRET

sql_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

jwt_secret_sql=$(sql_quote "$JWT_SECRET")

psql -X --set ON_ERROR_STOP=1 <<SQL
DO \$check\$
BEGIN
  IF to_regclass('settings.secrets') IS NULL THEN
    RAISE EXCEPTION 'settings.secrets does not exist; deploy the schema before configuring runtime secrets';
  END IF;
END
\$check\$;

SELECT settings.set('jwt_secret', '$jwt_secret_sql');
SQL
