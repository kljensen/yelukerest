#!/usr/bin/env sh
set -eu

if [ -f "${ENV_FILE:-.env}" ]; then
  set -a
  . "${ENV_FILE:-.env}"
  set +a
fi

ZAPADKA_BIN=${ZAPADKA_BIN:-zapadka}
target=${1:-development}

if ! command -v "$ZAPADKA_BIN" >/dev/null 2>&1; then
  echo "$ZAPADKA_BIN is required to deploy migrations." >&2
  exit 127
fi

exec "$ZAPADKA_BIN" deploy --target "$target"
