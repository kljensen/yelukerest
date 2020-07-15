#!/usr/bin/env bash

# This shell script is based on the one at https://git.io/fAX6Z
# created by the sqitch authors. It is a wrapper around the sqitch
# docker image that passes in appropriate environment variables,
# mounts appropriate directories, etc. such that the sqitch docker
# image can be used just like running sqitch locally. I altered
# the script in a few ways, particularly,
# 1. I source environment variables from the `.env` file
# 2. I set the `-C` option when running sqitch to change
#    directories to my migrations directory.
# Like other scripts in this `bin` directory, this script should
# be run from the top-level directory of the yelukerest project.

# klj - Source environment variables
set -a
. ./.env
set +a

MIGRATIONS_DIR="db/migrations"
export PGUSER="$SUPER_USER"
export PGPASS="$SUPER_USER_PASSWORD"
export SQITCH_PASSWORD="$SUPER_USER_PASSWORD"
# endklj

# Determine which Docker image to run.
SQITCH_IMAGE=${SQITCH_IMAGE:=sqitch/sqitch:latest}

# Set up required pass-through variables.
user=${USER-$(whoami)}
email=$(git config user.email)
passopt=(
    -e "DB_USER=$DB_USER"
    -e "DB_PASS=$DB_PASS"
    -e "SUPER_USER=$SUPER_USER"
    -e "SUPER_USER_PASSWORD=$SUPER_USER_PASSWORD"
    -e "JWT_SECRET=$JWT_SECRET"
    -e "SQITCH_ORIG_SYSUSER=$user"
    -e "SQITCH_ORIG_EMAIL=$email"
    -e "TZ=$(date +%Z)" \
    -e "LESS=${LESS:--R}" \
)

# Handle OS-specific options.
case "$(uname -s)" in
    Linux*)
        passopt+=(-e "SQITCH_ORIG_FULLNAME=$(getent passwd $user | cut -d: -f5 | cut -d, -f1)")
        passopt+=(-u $(id -u ${user}):$(id -g ${user}))
        ;;
    Darwin*)
        passopt+=(-e "SQITCH_ORIG_FULLNAME=$(id -P $user | awk -F '[:]' '{print $8}')")
        ;;
    MINGW*|CYGWIN*)
        passopt+=(-e "SQITCH_ORIG_FULLNAME=$(net user $user)")
        ;;
    *)
        echo "Unknown OS: $(uname -s)"
        exit 2
        ;;
esac

# Iterate over optional Sqitch and engine variables.
for var in \
    SQITCH_CONFIG SQITCH_USERNAME SQITCH_PASSWORD SQITCH_FULLNAME SQITCH_EMAIL SQITCH_TARGET \
    DBI_TRACE \
    PGUSER PGPASSWORD PGHOST PGHOSTADDR PGPORT PGDATABASE PGSERVICE PGOPTIONS PGSSLMODE PGREQUIRESSL PGSSLCOMPRESSION PGREQUIREPEER PGKRBSRVNAME PGKRBSRVNAME PGGSSLIB PGCONNECT_TIMEOUT PGCLIENTENCODING PGTARGETSESSIONATTRS \
    MYSQL_PWD MYSQL_HOST MYSQL_TCP_PORT \
    TNS_ADMIN TWO_TASK ORACLE_SID \
    ISC_USER ISC_PASSWORD \
    VSQL_HOST VSQL_PORT VSQL_USER VSQL_PASSWORD VSQL_SSLMODE \
    SNOWSQL_ACCOUNT SNOWSQL_USER SNOWSQL_PWD SNOWSQL_HOST SNOWSQL_PORT SNOWSQL_DATABASE SNOWSQL_REGION SNOWSQL_WAREHOUSE SNOWSQL_PRIVATE_KEY_PASSPHRASE
do
    if [ -n "${!var}" ]; then
       passopt+=(-e $var)
    fi
done

# Determine the name of the container home directory.
homedst=/home
if [ $(id -u ${user}) -eq 0 ]; then
    homedst=/root
fi
# Set HOME, since the user ID likely won't be the same as for the sqitch user.
passopt+=(-e "HOME=${homedst}")

# Run the container with the current and home directories mounted.
docker run -it --rm --network host \
    --mount "type=bind,src=$(pwd),dst=/repo" \
    --mount "type=bind,src=$HOME,dst=$homedst" \
    "${passopt[@]}" "$SQITCH_IMAGE" "$@"
