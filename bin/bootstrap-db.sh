#!/usr/bin/env sh
# Provision roles, deploy the immutable bootstrap, and install runtime secrets.
set -eu

if [ -f "${ENV_FILE:-.env}" ]; then
  set -a
  . "${ENV_FILE:-.env}"
  set +a
fi

target=${1:-development}
ZAPADKA_BIN=${ZAPADKA_BIN:-zapadka}

if ! command -v "$ZAPADKA_BIN" >/dev/null 2>&1; then
  echo "$ZAPADKA_BIN is required to bootstrap the database." >&2
  exit 127
fi

case "$target" in
  development)
    : "${YELUKEREST_DEV_DATABASE_URL:?YELUKEREST_DEV_DATABASE_URL is required}"
    ;;
  test-migrator)
    : "${YELUKEREST_TEST_MIGRATOR_DATABASE_URL:?YELUKEREST_TEST_MIGRATOR_DATABASE_URL is required}"
    ;;
  *)
    echo 'usage: bin/bootstrap-db.sh [development|test-migrator]' >&2
    exit 2
    ;;
esac

./bin/provision-db.sh
./authapp/sql/create-authapp-db-role.sh
"$ZAPADKA_BIN" deploy --target "$target"
./bin/configure-jwt-secret.sh
