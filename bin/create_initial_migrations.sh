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
echo "done"

#
# Initialize sqitch
#
SQITCH="./bin/sqitch.sh -C $MIGRATIONS_DIRECTORY"
echo "running sqitch init"
$SQITCH init yelukerest --uri https://github.com/kljensen/yelukerest --engine pg
echo "done"

#
# Create a migration for our global roles
#
ROLES=$(PGPASSWORD=$SUPER_USER_PASSWORD pg_dumpall \
    --host $DB_DEV_HOST --port $DB_PORT \
     -U $SUPER_USER \
     -r)

$SQITCH add roles -n "Add global roles"
cat << EOF > $MIGRATIONS_DIRECTORY/deploy/roles.sql
BEGIN;

-- Initial database roles.
$ROLES

COMMIT;
EOF

#
# Create a migration for our initial DDL
#
DDL=$(PGPASSWORD=$SUPER_USER_PASSWORD pg_dump \
    --host $DB_DEV_HOST --port $DB_PORT \
     -U $SUPER_USER \
     -s \
     $@ \
     $DB_NAME)

$SQITCH add ddl --requires roles -n "Add initial ddl"
cat << EOF > $MIGRATIONS_DIRECTORY/deploy/ddl.sql
BEGIN;

$DDL

COMMIT;
EOF

#
# Create the migration for our inital data
#
$SQITCH add data --requires ddl -n "Add initial data"
cat << EOF > $MIGRATIONS_DIRECTORY/deploy/data.sql
BEGIN;

SET search_path = settings, pg_catalog, public;

INSERT INTO secrets (key, value) VALUES ('jwt_lifetime','3600');
INSERT INTO secrets (key, value) VALUES ('auth.default-role','anonymous');
INSERT INTO secrets (key, value) VALUES ('auth.data-schema','data');
INSERT INTO secrets (key, value) VALUES ('auth.api-schema','api');

COMMIT;
EOF