#!/bin/bash
# Connect to PG
if [ -z "$1" ]
  then
    echo "You must supply a host"
fi
if [ -z "$1" ]
  then
    echo "You must supply a port"
fi

# Dump the table

PGPASSWORD=$SUPER_USER_PASSWORD pg_dump \
    --host $1 --port $2 \
     -U $SUPER_USER \
     -c \
    $DB_NAME 