#!/bin/bash

# This script will dump all the roles needed on our pg system/cluster. Roles are
# global and NOT specific to the database. We have various roles like 'ta', 'faculty',
# and 'authenticator'. The database permissions will depend on these roles, e.g.
# the `api` views are owned by the `api` role. 

# Source environment variables
set -a
. ./.env
set +a

# Dump the table
PGPASSWORD=$SUPER_USER_PASSWORD pg_dumpall \
    --host $DB_DEV_HOST --port $DB_PORT \
     -U $SUPER_USER \
     -roles-only --clean
