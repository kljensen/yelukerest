#!/bin/bash
# Dumps the data in a particular table as insert statements.
# Uses the settings from the `.env` file in the directory from
# which the script is called.
if [ -z "$1" ]
  then
    echo "You must supply a container name to which you wish a connection"
fi

# Source environment variables
set -a
. ./.env
set +a

# set -x
set -v

docker exec -it "${COMPOSE_PROJECT_NAME}_${1}_1" /bin/bash