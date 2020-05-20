#!/usr/bin/env sh

if [ "$#" -ne 1 ] ; then
  echo "Usage: $0 JSON" >&2
  exit 1
fi

# Source environment variables
set -a
. ./.env
set +a

# Run the node script for creating a jwt
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
node $dir/_jwt.js "$@"
