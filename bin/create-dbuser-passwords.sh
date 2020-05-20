#!/bin/bash
# Connect to PG

# Source environment variables
set -a
. ./.env
set +a


echo ALTER ROLE $DB_USER WITH LOGIN PASSWORD \'$DB_PASS\'\;

# Dump the table
PGPASSWORD=$SUPER_USER_PASSWORD psql \
    --host $DB_DEV_HOST --port $DB_PORT \
     -U $SUPER_USER \
    $DB_NAME <<EOF
ALTER ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';
EOF
