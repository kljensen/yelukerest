#!/usr/bin/env sh
# Provision cluster-global roles before the immutable database bootstrap.
set -eu

if [ -f "${ENV_FILE:-.env}" ]; then
  set -a
  . "${ENV_FILE:-.env}"
  set +a
fi

: "${DB_NAME:?DB_NAME is required}"
: "${DB_USER:?DB_USER is required}"
: "${DB_PASS:?DB_PASS is required}"
: "${SUPER_USER:?SUPER_USER is required}"
: "${SUPER_USER_PASSWORD:?SUPER_USER_PASSWORD is required}"

: "${YELUKEREST_MIGRATOR_ROLE:=yelukerest_migrator}"
: "${YELUKEREST_MIGRATOR_PASSWORD:?YELUKEREST_MIGRATOR_PASSWORD is required}"

if [ "$YELUKEREST_MIGRATOR_ROLE" != 'yelukerest_migrator' ]; then
  echo 'YELUKEREST_MIGRATOR_ROLE must be yelukerest_migrator because immutable migrations name that owner.' >&2
  exit 1
fi

export PGUSER="${PROVISION_ADMIN_USER:-$SUPER_USER}"
export PGPASSWORD="${PROVISION_ADMIN_PASSWORD:-$SUPER_USER_PASSWORD}"
export PGDATABASE="$DB_NAME"
export PGHOST="${PGHOST:-${DB_DEV_HOST:-localhost}}"
export PGPORT="${PGPORT:-${DB_PORT:-5432}}"
sql_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

migrator_role_sql=$(sql_quote "$YELUKEREST_MIGRATOR_ROLE")
migrator_password_sql=$(sql_quote "$YELUKEREST_MIGRATOR_PASSWORD")
authenticator_role_sql=$(sql_quote "$DB_USER")
authenticator_password_sql=$(sql_quote "$DB_PASS")

psql -X --set ON_ERROR_STOP=1 <<SQL
DO \$provision\$
DECLARE
  migrator_role text := '$migrator_role_sql';
  migrator_password text := '$migrator_password_sql';
  authenticator_role text := '$authenticator_role_sql';
  authenticator_password text := '$authenticator_password_sql';
  role_name text;
BEGIN
  -- grant_consumer is the role a data-grant credential switches PostgREST into;
  -- grant_reader owns the one function it may call (ADR 0005, issue #385).
  -- Both are cluster-wide roles, so they are provisioned here like every other
  -- role and the add-grant-consumer-role migration refuses to deploy without
  -- them.
  FOREACH role_name IN ARRAY ARRAY['anonymous', 'api', 'app', 'faculty', 'observer', 'student', 'ta', 'grant_consumer', 'grant_reader']
  LOOP
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = role_name) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', role_name);
    ELSE
      EXECUTE format('ALTER ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', role_name);
    END IF;
  END LOOP;

  -- quiz_importer owns api.import_quiz_results, the one write TAs may run
  -- (issue #389). NOINHERIT as well: it acts through its own grants alone,
  -- and the add-ta-quiz-import migration refuses to deploy otherwise.
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'quiz_importer') THEN
    EXECUTE 'CREATE ROLE quiz_importer NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS';
  ELSE
    EXECUTE 'ALTER ROLE quiz_importer NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = migrator_role) THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', migrator_role, migrator_password);
  ELSE
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', migrator_role, migrator_password);
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = authenticator_role) THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', authenticator_role, authenticator_password);
  ELSE
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', authenticator_role, authenticator_password);
  END IF;

  EXECUTE format('GRANT CREATE, CONNECT, TEMPORARY ON DATABASE %I TO %I', current_database(), migrator_role);
  EXECUTE format('GRANT CREATE ON SCHEMA public TO %I', migrator_role);
  EXECUTE format('GRANT %I TO %I', 'api', migrator_role);
  -- The migrator must be a member of grant_reader to hand it ownership of the
  -- reader function. The authenticator must not be: nothing PostgREST serves
  -- may switch into the role that can read every submission.
  EXECUTE format('GRANT %I TO %I', 'grant_reader', migrator_role);
  -- Likewise quiz_importer: the migrator hands it the import; the
  -- authenticator must never be able to switch into the role that writes
  -- grades.
  EXECUTE format('GRANT %I TO %I', 'quiz_importer', migrator_role);
  FOREACH role_name IN ARRAY ARRAY['anonymous', 'app', 'faculty', 'observer', 'student', 'ta', 'grant_consumer']
  LOOP
    EXECUTE format('GRANT %I TO %I', role_name, authenticator_role);
  END LOOP;
END
\$provision\$;

DO \$verify\$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_auth_members membership
    JOIN pg_roles granted ON granted.oid = membership.roleid
    JOIN pg_roles member ON member.oid = membership.member
    WHERE granted.rolname = 'student'
      AND member.rolname = '$authenticator_role_sql'
  ) THEN
    RAISE EXCEPTION 'authenticator role is missing required student membership';
  END IF;
END
\$verify\$;
SQL
