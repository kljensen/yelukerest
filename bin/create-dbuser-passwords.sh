#!/bin/bash
# Connect to PG

# Source environment variables
set -a
. ./.env
set +a

# Dump the table
PGPASSWORD=$SUPER_USER_PASSWORD psql \
    --host $DB_DEV_HOST --port $DB_PORT \
     -U $SUPER_USER \
    $DB_NAME <<EOF
ALTER ROLE $DB_USER PASSWORD '$DB_PASS';
ALTER ROLE $AUTHAPP_DB_USER PASSWORD '$AUTHAPP_DB_PASS';
EOF