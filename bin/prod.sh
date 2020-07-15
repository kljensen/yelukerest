#!/bin/sh
set -o xtrace
docker-compose -f docker-compose.base.yaml -f docker-compose.prod.yaml $@
