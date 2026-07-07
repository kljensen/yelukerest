#!/bin/bash
# Connect to PG

# This script creates the initial migrations in the `db/migrations` directory
# based on the database schema running in a development environment. That is,
# whatever schema we're running in development is dumped to a set of sqitch
# migrations so that I can use sqitch to bring up a database in production.
#
# I put everything in a script in part so I remember how to do it in the future!
# In future years, I might want to have different migrations for different
# versions/releases. E.g. Fall 2020 migrations, Spring 2021 migrations, etc.
# Right now I only need on set of migrations because each instance of yelukerest
# is used only for a single semester. So, at the beginning of each semester I 
# will typically create a new set of migrations.
#
# For more information about migrations and this project, see
# https://docs.subzero.cloud/managing-migrations/ and
# https://sqitch.org/docs/manual/sqitchtutorial/
#

# Source environment variables. Allow callers to override the host port used
# for local development when another service already owns .env's DB_PORT.
DB_PORT_OVERRIDE="${DB_PORT:-}"
set -a
. ./.env
set +a
if [ -n "$DB_PORT_OVERRIDE" ]; then
    DB_PORT="$DB_PORT_OVERRIDE"
fi

MIGRATIONS_DIRECTORY="db/migrations"
echo "Removing old migrations directory at $MIGRATIONS_DIRECTORY"
rm -rf $MIGRATIONS_DIRECTORY/*

#
# Initialize sqitch. Prefer the historical Docker wrapper, but allow local
# sqitch for environments where passing secrets into Docker is undesirable.
#
SQITCH="${YELUKEREST_SQITCH_BIN:-./bin/sqitch.sh} -C $MIGRATIONS_DIRECTORY"
$SQITCH init yelukerest --uri https://github.com/kljensen/yelukerest --engine pg

#
# Create a migration for our global roles
#
# Here, we I dump all the role information from the
# database. We do some processing on those SQL statements.
# 1. Remove any reference to the superuser. This should
#    be created when the database is first created.
#    The migration will typically be run as the superuser!
# 2. Set passwords using environment variables. Notice
#    that these will need to be passed to sqitch when it
#    is run (see comment below).
# 3. Don't mess with the "postgres" user. Comment out all
#    those lines.
# 4. Replace references to the super user on this system
#    with a value pulled from the environment. recall that
#    the role name associated with the super user is set 
#    by the environment so that it migh tbe 'superuser' on
#    on system and 'foobaruser' on another.
#
ROLES=$(PGPASSWORD=$SUPER_USER_PASSWORD pg_dumpall \
    --host $DB_DEV_HOST --port $DB_PORT \
     -U $SUPER_USER \
     --roles-only | \
     grep -v "ROLE $SUPER_USER" | \
     sed "
        /ROLE postgres/ s/^/-- /;
        /ROLE $SUPER_USER/ s/^/-- /;
        s/$DB_USER/:authenticator_user/;
        /$DB_USER/ s/PASSWORD.*/PASSWORD :'authenticator_pass';/;
        s/$SUPER_USER/:super_user/g;
     "
)

$SQITCH add roles -n "Add global roles"
cat << EOF > $MIGRATIONS_DIRECTORY/deploy/roles.sql

-- This file was created automatically by the create-initial-migrations.sh
-- script. DO NOT EDIT BY HAND.

BEGIN;

-- When we dump the data it will include the current (dev) authenticator
-- (postgrest) user and superuser info. We don't want that. Here, we're
-- going to replace those with values from the environment. That assumes
-- that sqitch will have access to those environment variables when it
-- runs. See the "bin/sqitch.sh" wrapper via which these environment
-- variables are explicitly passed in.
\set authenticator_user \`echo \$DB_USER\`
\set authenticator_pass \`echo \$DB_PASS\`
\set super_user \`echo \$SUPER_USER\`

-- Initial database roles.
$ROLES

COMMIT;
EOF

cat << EOF > $MIGRATIONS_DIRECTORY/verify/roles.sql
-- Verify yelukerest:roles on pg

BEGIN;

\set authenticator_user \`echo \$DB_USER\`
\set super_user \`echo \$SUPER_USER\`

SELECT 1 / count(*) FROM pg_roles WHERE rolname = :'super_user';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = :'authenticator_user';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'anonymous';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'api';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'app';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'faculty';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'observer';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'student';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'ta';

SELECT 1 / count(*)
FROM pg_auth_members m
JOIN pg_roles role_granted ON role_granted.oid = m.roleid
JOIN pg_roles member ON member.oid = m.member
WHERE role_granted.rolname = 'student'
AND member.rolname = :'authenticator_user';

SELECT 1 / count(*)
FROM pg_auth_members m
JOIN pg_roles role_granted ON role_granted.oid = m.roleid
JOIN pg_roles member ON member.oid = m.member
WHERE role_granted.rolname = 'faculty'
AND member.rolname = :'authenticator_user';

ROLLBACK;
EOF

cat << EOF > $MIGRATIONS_DIRECTORY/revert/roles.sql
-- Revert yelukerest:roles from pg

BEGIN;

DO \$\$
BEGIN
    RAISE EXCEPTION 'Yelukerest bootstrap migrations are irreversible; rebuild or drop the disposable database instead.';
END \$\$;

COMMIT;
EOF

# Create a migration for our initial DDL
#
DDL=$(PGPASSWORD=$SUPER_USER_PASSWORD pg_dump \
    --host $DB_DEV_HOST --port $DB_PORT \
     -U $SUPER_USER \
     -s \
     $@ \
     --exclude-schema=sqitch \
     $DB_NAME)

$SQITCH add ddl --requires roles -n "Add initial ddl"
cat << EOF > $MIGRATIONS_DIRECTORY/deploy/ddl.sql

-- This file was created automatically by the create-initial-migrations.sh
-- script. DO NOT EDIT BY HAND.

BEGIN;

$DDL

COMMIT;
EOF

cat << EOF > $MIGRATIONS_DIRECTORY/verify/ddl.sql
-- Verify yelukerest:ddl on pg

BEGIN;

DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'api') THEN
        RAISE EXCEPTION 'missing api schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'data') THEN
        RAISE EXCEPTION 'missing data schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN
        RAISE EXCEPTION 'missing auth schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'settings') THEN
        RAISE EXCEPTION 'missing settings schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'request') THEN
        RAISE EXCEPTION 'missing request schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgjwt') THEN
        RAISE EXCEPTION 'missing pgjwt schema';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_submission'
    ) THEN
        RAISE EXCEPTION 'missing data.assignment_submission table';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_submission'
        AND a.attname = 'is_team'
        AND a.attnotnull
    ) THEN
        RAISE EXCEPTION 'data.assignment_submission.is_team is not NOT NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment'
        AND a.attname = 'is_team'
        AND a.attnotnull
    ) THEN
        RAISE EXCEPTION 'data.assignment.is_team is not NOT NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE n.nspname = 'data'
        AND c.relname = 'quiz'
        AND a.attname = 'is_offline'
        AND a.attnotnull
        AND pg_get_expr(d.adbin, d.adrelid) = 'true'
    ) THEN
        RAISE EXCEPTION 'data.quiz.is_offline must be NOT NULL DEFAULT true';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'quiz_answer'
    ) THEN
        RAISE EXCEPTION 'data.quiz_answer should not exist for paper-only quizzes';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'auth'
        AND p.proname = 'sign_jwt'
        AND p.proconfig @> ARRAY['search_path=pg_catalog, auth, settings, pgjwt, pg_temp']
    ) THEN
        RAISE EXCEPTION 'auth.sign_jwt search_path is not pinned';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'settings'
        AND p.proname = 'get'
        AND p.proconfig @> ARRAY['search_path=pg_catalog, settings, pg_temp']
    ) THEN
        RAISE EXCEPTION 'settings.get search_path is not pinned';
    END IF;
END \$\$;

ROLLBACK;
EOF

cat << EOF > $MIGRATIONS_DIRECTORY/revert/ddl.sql
-- Revert yelukerest:ddl from pg

BEGIN;

DO \$\$
BEGIN
    RAISE EXCEPTION 'Yelukerest bootstrap migrations are irreversible; rebuild or drop the disposable database instead.';
END \$\$;

COMMIT;
EOF

#
# Create the migration for our inital data
#
$SQITCH add data --requires ddl -n "Add initial data"
cat << EOF > $MIGRATIONS_DIRECTORY/deploy/data.sql

-- This file was created automatically by the create-initial-migrations.sh
-- script. DO NOT EDIT BY HAND.

BEGIN;
\set jwt_secret \`echo \$JWT_SECRET\`

SET search_path = settings, pg_catalog, public;

INSERT INTO secrets (key, value) VALUES ('jwt_lifetime','3600');
INSERT INTO secrets (key, value) VALUES ('auth.default-role','anonymous');
INSERT INTO secrets (key, value) VALUES ('auth.data-schema','data');
INSERT INTO secrets (key, value) VALUES ('auth.api-schema','api');
INSERT INTO secrets (key, value) VALUES ('jwt_secret',:'jwt_secret');

COMMIT;
EOF

cat << EOF > $MIGRATIONS_DIRECTORY/verify/data.sql
-- Verify yelukerest:data on pg

BEGIN;

DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'jwt_lifetime'
        AND value = '3600'
    ) THEN
        RAISE EXCEPTION 'missing jwt_lifetime setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'auth.default-role'
        AND value = 'anonymous'
    ) THEN
        RAISE EXCEPTION 'missing auth.default-role setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'auth.data-schema'
        AND value = 'data'
    ) THEN
        RAISE EXCEPTION 'missing auth.data-schema setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'auth.api-schema'
        AND value = 'api'
    ) THEN
        RAISE EXCEPTION 'missing auth.api-schema setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'jwt_secret'
        AND value <> ''
    ) THEN
        RAISE EXCEPTION 'missing jwt_secret setting';
    END IF;
END \$\$;

ROLLBACK;
EOF

cat << EOF > $MIGRATIONS_DIRECTORY/revert/data.sql
-- Revert yelukerest:data from pg

BEGIN;

DO \$\$
BEGIN
    RAISE EXCEPTION 'Yelukerest bootstrap migrations are irreversible; rebuild or drop the disposable database instead.';
END \$\$;

COMMIT;
EOF
