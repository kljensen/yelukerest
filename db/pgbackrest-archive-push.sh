#!/bin/sh
set -eu

if [ -z "${S3_ACCESS_KEY_ID:-}" ] || [ "${S3_ACCESS_KEY_ID}" = "**None**" ]; then
  echo "You need to set the S3_ACCESS_KEY_ID environment variable." >&2
  exit 1
fi

if [ -z "${S3_SECRET_ACCESS_KEY:-}" ] || [ "${S3_SECRET_ACCESS_KEY}" = "**None**" ]; then
  echo "You need to set the S3_SECRET_ACCESS_KEY environment variable." >&2
  exit 1
fi

if [ -z "${S3_BUCKET:-}" ] || [ "${S3_BUCKET}" = "**None**" ]; then
  echo "You need to set the S3_BUCKET environment variable." >&2
  exit 1
fi

PGBACKREST_STANZA=${PGBACKREST_STANZA:-yelukerest}
PGBACKREST_REPO1_PATH=${PGBACKREST_REPO1_PATH:-/pgbackrest}
PGBACKREST_REPO1_TYPE=${PGBACKREST_REPO1_TYPE:-s3}
PGBACKREST_REPO1_S3_URI_STYLE=${PGBACKREST_REPO1_S3_URI_STYLE:-host}
PGBACKREST_REPO1_STORAGE_PORT=${PGBACKREST_REPO1_STORAGE_PORT:-443}
PGBACKREST_REPO1_STORAGE_VERIFY_TLS=${PGBACKREST_REPO1_STORAGE_VERIFY_TLS:-y}
POSTGRES_DATA_PATH=${POSTGRES_DATA_PATH:-/var/lib/postgresql/18/docker}
S3_ENDPOINT=${S3_ENDPOINT:-**None**}
S3_PREFIX=${S3_PREFIX:-pgbackrest}
S3_REGION=${S3_REGION:-us-east-1}

REPO_PATH=$PGBACKREST_REPO1_PATH
if [ -n "$S3_PREFIX" ]; then
  REPO_PATH="/${S3_PREFIX}"
fi

CONFIG=$(mktemp)
trap 'rm -f "$CONFIG"' EXIT

cat > "$CONFIG" <<EOF
[global]
repo1-type=${PGBACKREST_REPO1_TYPE}
repo1-path=${REPO_PATH}
repo1-s3-bucket=${S3_BUCKET}
repo1-s3-key=${S3_ACCESS_KEY_ID}
repo1-s3-key-secret=${S3_SECRET_ACCESS_KEY}
repo1-s3-region=${S3_REGION}
repo1-s3-uri-style=${PGBACKREST_REPO1_S3_URI_STYLE}
repo1-storage-port=${PGBACKREST_REPO1_STORAGE_PORT}
repo1-storage-verify-tls=${PGBACKREST_REPO1_STORAGE_VERIFY_TLS}
log-level-console=info

[${PGBACKREST_STANZA}]
pg1-path=${POSTGRES_DATA_PATH}
EOF

if [ "$S3_ENDPOINT" != "**None**" ] && [ -n "$S3_ENDPOINT" ]; then
  cat >> "$CONFIG" <<EOF
repo1-s3-endpoint=${S3_ENDPOINT}
EOF
fi

exec pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" archive-push "$1"
