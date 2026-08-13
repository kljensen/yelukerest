#!/usr/bin/env sh
set -eu

if [ -f "${ENV_FILE:-.env}" ]; then
  set -a
  . "${ENV_FILE:-.env}"
  set +a
fi

ZAPADKA_BIN="${ZAPADKA_BIN:-zapadka}"

if ! command -v "$ZAPADKA_BIN" >/dev/null 2>&1; then
  echo "$ZAPADKA_BIN is required to run database tests." >&2
  exit 127
fi

: "${YELUKEREST_TEST_DATABASE_URL:?YELUKEREST_TEST_DATABASE_URL is required and must use a privileged disposable-test role}"

./bin/reset_db.sh

exec "$ZAPADKA_BIN" test --target test
