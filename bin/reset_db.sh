#!/bin/bash
# Connect to PG

# Source environment variables
set -a
. ./.env
set +a

RESET_FILE="sample_data/reset.sql"

# See if we have psql installed locally
if [ -x "$(command -v psql)" ]; then
    # Connect through our host system psql (thus loading
    # the user's .inputrc and other niceities)
    PGPASSWORD=$SUPER_USER_PASSWORD \
        psql --host localhost --port $DB_PORT -U $SUPER_USER  $DB_NAME \
        -f "./db/src/$RESET_FILE"
else
    # Connect through psql in the docker container
    PGPASSWORD=$SUPER_USER_PASSWORD \
        docker exec -it "${COMPOSE_PROJECT_NAME}_db_1" \
        psql -U $SUPER_USER  $DB_NAME \
        -f "/docker-entrypoint-initdb.d/$RESET_FILE"
fi