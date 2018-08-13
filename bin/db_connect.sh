#!/bin/bash
# Connect to PG

# Source environment variables
set -a
. ./.env
set +a

# Dump the table
PGPASSWORD=$SUPER_USER_PASSWORD docker exec -it "${COMPOSE_PROJECT_NAME}_db_1" psql -U $SUPER_USER  $DB_NAME