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
    $DB_NAME 