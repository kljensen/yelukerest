#!/usr/bin/env sh
# Create the migration container for a new table or related schema change.
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: bin/new-table.sh <table-name>" >&2
  exit 2
fi

ZAPADKA_BIN=${ZAPADKA_BIN:-zapadka}

if ! command -v "$ZAPADKA_BIN" >/dev/null 2>&1; then
  echo "$ZAPADKA_BIN is required to create a migration." >&2
  exit 127
fi

exec "$ZAPADKA_BIN" new "add-$1"
