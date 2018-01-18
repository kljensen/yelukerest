#!/bin/bash
# Connect to PG
if [ -z "$1" ]
  then
    echo "You must supply a host"
    exit
fi
if [ -z "$1" ]
  then
    echo "You must supply a port"
    exit
fi
if [ -z "$3" ]
  then
    echo "You must supply an output directory"
    exit
fi

# Dump the table

PGPASSWORD=$SUPER_USER_PASSWORD pg_dumpall \
    --host $1 --port $2 \
     -U $SUPER_USER \
     -g \
    $DB_NAME >$3/globals.sql 

PGPASSWORD=$SUPER_USER_PASSWORD pg_dump \
    --host $1 --port $2 \
     -U $SUPER_USER \
     -Fp -s -v -f $3/schema.sql \
    $DB_NAME


PGPASSWORD=$SUPER_USER_PASSWORD pg_dump \
    --host $1 --port $2 \
     -U $SUPER_USER \
    -Fc -v -f $3/full.dump \
    $DB_NAME
