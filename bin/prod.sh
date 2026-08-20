#!/bin/sh
# Wrapper around `docker compose` for the production overlay.
#
# Tracing is OPT-IN. It used to be unconditional (`set -o xtrace`), which echoed
# every argument -- so a command that legitimately passes a secret, such as the
# documented Hydra bootstrap
#
#   ./bin/prod.sh exec -e HYDRA_DB_PASS="$HYDRA_DB_PASS" db bash /opt/hydra/create-hydra-db.sh
#
# printed that password in cleartext to the terminal, into shell scrollback, and
# into any CI or session log capturing stdout. Set YELUKEREST_TRACE=1 to turn it
# back on when debugging a command you know carries no secrets.
if [ -n "${YELUKEREST_TRACE:-}" ]; then
    set -o xtrace
fi

docker compose -f docker-compose.base.yaml -f docker-compose.prod.yaml "$@"
