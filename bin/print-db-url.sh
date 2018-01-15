
#!/bin/bash
# Print database URL for current environment
if [ -z "$1" ]
  then
    echo "You must supply dot env file from which to source env vars"
    exit 1
fi

# Source environment variables
set -a
. $1
set +a

URL="postgresql://${SUPER_USER}:${SUPER_USER_PASSWORD}@${DB_DEV_HOST}:${DB_PORT}/${DB_NAME}"
echo $URL
