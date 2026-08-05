#!/bin/bash
# Connect to PG
# Fail fast: a failed application dump must fail the whole script even
# when the optional Hydra dump below succeeds.
set -e
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

# Also dump the dedicated Ory Hydra database (OAuth clients, consent
# sessions, JWKs) when it exists. See docs/hydra.md for the restore
# procedure. Skipped silently on stacks without Hydra's database
# (e.g. dev, where Hydra runs with dsn=memory).
HYDRA_DB_NAME=${HYDRA_DB_NAME:-hydra}
if PGPASSWORD=$SUPER_USER_PASSWORD psql \
    --host $1 --port $2 \
    -U $SUPER_USER -d postgres -Atc \
    "select 1 from pg_database where datname = '$HYDRA_DB_NAME'" | grep -q 1; then
    PGPASSWORD=$SUPER_USER_PASSWORD pg_dump \
        --host $1 --port $2 \
        -U $SUPER_USER \
        -Fc -v -f $3/hydra.dump \
        $HYDRA_DB_NAME
else
    echo "No '$HYDRA_DB_NAME' database found; skipping Hydra dump"
fi
