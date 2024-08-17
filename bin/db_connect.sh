#!/bin/bash
# Connect to PG

# Source environment variables
set -a
. ./.env
set +a

# See if we have psql installed locally
if [ -x "$(command -v psql)" ]; then
    # Connect through our host system psql (thus loading
    # the user's .inputrc and other niceities)
    PGPASSWORD=$SUPER_USER_PASSWORD \
        psql --host localhost --port $DB_PORT -U $SUPER_USER  $DB_NAME 
else
    # Connect through psql in the docker container
    PGPASSWORD=$SUPER_USER_PASSWORD \
        docker exec -it "${COMPOSE_PROJECT_NAME}-db-1" \
        psql -U $SUPER_USER  $DB_NAME 
fi