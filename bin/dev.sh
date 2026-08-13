#!/bin/sh
set -o xtrace

# Provisioning and migrations are a separate bootstrap step.
exec docker compose -f docker-compose.base.yaml -f docker-compose.dev.yaml "$@"
