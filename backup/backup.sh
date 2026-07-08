#!/bin/sh

set -e

if [ -z "${S3_ACCESS_KEY_ID:-}" ] || [ "${S3_ACCESS_KEY_ID}" = "**None**" ]; then
  echo "You need to set the S3_ACCESS_KEY_ID environment variable."
  exit 1
fi

if [ -z "${S3_SECRET_ACCESS_KEY:-}" ] || [ "${S3_SECRET_ACCESS_KEY}" = "**None**" ]; then
  echo "You need to set the S3_SECRET_ACCESS_KEY environment variable."
  exit 1
fi

if [ "${S3_BUCKET}" = "**None**" ]; then
  echo "You need to set the S3_BUCKET environment variable."
  exit 1
fi

if [ "${POSTGRES_USER}" = "**None**" ]; then
  echo "You need to set the POSTGRES_USER environment variable."
  exit 1
fi

if [ -z "${POSTGRES_PASSWORD:-}" ] || [ "${POSTGRES_PASSWORD}" = "**None**" ]; then
  echo "You need to set the POSTGRES_PASSWORD environment variable or link to a container named POSTGRES."
  exit 1
fi

if [ ! -d "$POSTGRES_DATA_PATH" ]; then
  echo "Postgres data path does not exist: $POSTGRES_DATA_PATH"
  exit 1
fi

if [ ! -d "$POSTGRES_SOCKET_PATH" ]; then
  echo "Postgres socket path does not exist: $POSTGRES_SOCKET_PATH"
  exit 1
fi

export PGPASSWORD="$POSTGRES_PASSWORD"
REPO_PATH=$PGBACKREST_REPO1_PATH

if [ -n "${S3_PREFIX:-}" ]; then
  REPO_PATH="/${S3_PREFIX}"
fi

CONFIG=$(mktemp)
trap 'rm -f "$CONFIG"' EXIT

cat > "$CONFIG" <<EOF
[global]
repo1-type=${PGBACKREST_REPO1_TYPE}
repo1-path=${REPO_PATH}
repo1-retention-full=${PGBACKREST_REPO1_RETENTION_FULL}
repo1-s3-bucket=${S3_BUCKET}
repo1-s3-key=${S3_ACCESS_KEY_ID}
repo1-s3-key-secret=${S3_SECRET_ACCESS_KEY}
repo1-s3-region=${S3_REGION}
repo1-s3-uri-style=${PGBACKREST_REPO1_S3_URI_STYLE}
repo1-storage-port=${PGBACKREST_REPO1_STORAGE_PORT}
repo1-storage-verify-tls=${PGBACKREST_REPO1_STORAGE_VERIFY_TLS}
log-level-console=info
start-fast=y

[${PGBACKREST_STANZA}]
pg1-path=${POSTGRES_DATA_PATH}
pg1-port=${POSTGRES_PORT}
pg1-socket-path=${POSTGRES_SOCKET_PATH}
pg1-user=${POSTGRES_USER}
EOF

if [ "${S3_ENDPOINT}" != "**None**" ] && [ -n "${S3_ENDPOINT}" ]; then
  cat >> "$CONFIG" <<EOF
repo1-s3-endpoint=${S3_ENDPOINT}
EOF
fi

pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" stanza-create
pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" check
pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" backup
pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" info
