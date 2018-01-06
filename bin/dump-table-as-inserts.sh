#!/bin/bash
# Dumps the data in a particular table as insert statements.
# Uses the settings from the `.env` file in the directory from
# which the script is called.
if [ -z "$1" ]
  then
    echo "You must supply a table name to dump"
fi

# Source environment variables
set -a
. ./.env
set +a

# set -x
set -v

# Dump the table
PGPASSWORD=$SUPER_USER_PASSWORD pg_dump --table $1 --data-only --column-inserts \
    --host $DB_DEV_HOST --port $DB_PORT \
     -U $SUPER_USER \
    $DB_NAME 