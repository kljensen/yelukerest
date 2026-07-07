#!/bin/bash
# Connect to PG

# Source environment variables
set -a
. ./.env
set +a

RESET_FILE="sample_data/reset.sql"
DB_TEST_HOST="${DB_TEST_HOST:-localhost}"
DB_TEST_PORT="${DB_TEST_PORT:-$DB_PORT}"

# See if we have psql installed locally
if [ -x "$(command -v psql)" ]; then
    # Connect through our host system psql (thus loading
    # the user's .inputrc and other niceities)
    PGPASSWORD=$SUPER_USER_PASSWORD \
        psql --host "$DB_TEST_HOST" --port "$DB_TEST_PORT" -U $SUPER_USER  $DB_NAME \
        -f "./db/src/$RESET_FILE"
else
    # Connect through psql in the docker container
    PGPASSWORD=$SUPER_USER_PASSWORD \
        docker compose -f docker-compose.base.yaml -f docker-compose.dev.yaml exec -T db \
        psql -U $SUPER_USER  $DB_NAME \
        -f "/docker-entrypoint-initdb.d/$RESET_FILE"
fi
