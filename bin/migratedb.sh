
#!/bin/bash
# Run migrations
if [ -z "$1" ]
  then
    echo "You must supply dot env file from which to source env vars"
    exit 1
fi


# Source environment variables
set -a
. $1
set +a

# set -x
set -v

# Dump the table
    # deploy <url>          Deploy sqitch migrations to a production database, url must have the
    # `db:pg://${user}:${pass}@${host}:${port}/${db}` format
URL="db:pg://${SUPER_USER}:${SUPER_USER_PASSWORD}@${DB_DEV_HOST}:${DB_PORT}/${DB_NAME}"
echo "Going to deploy to $URL"
./node_modules/.bin/subzero-migrations deploy ${URL}