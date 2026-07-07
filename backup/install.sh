#! /bin/sh

set -e

apk add --no-cache \
  pgbackrest \
  postgresql18-client
