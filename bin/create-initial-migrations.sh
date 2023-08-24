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

# Source environment variables
set -a
. ./.env
set +a

MIGRATIONS_DIRECTORY="db/migrations"
echo "Removing old migrations directory at $MIGRATIONS_DIRECTORY"
rm -rf $MIGRATIONS_DIRECTORY/*

#
# Initialize sqitch
#
SQITCH="./bin/sqitch.sh -C $MIGRATIONS_DIRECTORY"
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
