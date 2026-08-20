#!/bin/sh
# Wrapper around `docker compose` for the development overlay.
#
# Tracing is OPT-IN; see the note in bin/prod.sh. Set YELUKEREST_TRACE=1 to
# echo the compose invocation.
if [ -n "${YELUKEREST_TRACE:-}" ]; then
    set -o xtrace
fi

# Provisioning and migrations are a separate bootstrap step.
exec docker compose -f docker-compose.base.yaml -f docker-compose.dev.yaml "$@"
