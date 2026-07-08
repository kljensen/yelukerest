#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_NAME=${YELUKEREST_PGBACKREST_TEST_PROJECT:-yelukerest-pgbackrest-test}
DB_PORT=${YELUKEREST_PGBACKREST_TEST_DB_PORT:-55433}
PG_VOLUME_NAME=${YELUKEREST_PGBACKREST_TEST_PG_VOLUME:-${PROJECT_NAME}-pg-data}
RESTORE_VOLUME_NAME=${YELUKEREST_PGBACKREST_TEST_RESTORE_VOLUME:-${PROJECT_NAME}-pg-restore}
RESTORE_CONTAINER_NAME=${YELUKEREST_PGBACKREST_TEST_RESTORE_CONTAINER:-${PROJECT_NAME}-restore-db}
OVERRIDE_FILE=${YELUKEREST_PGBACKREST_TEST_COMPOSE_OVERRIDE:-tmp/docker-compose.pgbackrest-test.yaml}
KEEP_STACK=${YELUKEREST_PGBACKREST_TEST_KEEP_STACK:-}
MINIO_CERT_DIR=tmp/pgbackrest-minio-certs
MINIO_IMAGE=${YELUKEREST_PGBACKREST_TEST_MINIO_IMAGE:-quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e}
MINIO_MC_IMAGE=${YELUKEREST_PGBACKREST_TEST_MINIO_MC_IMAGE:-quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727}

cd "$ROOT_DIR"
mkdir -p "$(dirname "$OVERRIDE_FILE")"
mkdir -p "$MINIO_CERT_DIR"
docker volume create "$PG_VOLUME_NAME" >/dev/null
docker volume create "$RESTORE_VOLUME_NAME" >/dev/null

env_value() {
    sed -n "s/^$1=//p" .env | tail -n 1 | sed "s/^'//; s/'$//; s/^\"//; s/\"$//"
}

SUPER_USER_VALUE=${SUPER_USER:-$(env_value SUPER_USER)}
SUPER_USER_PASSWORD_VALUE=${SUPER_USER_PASSWORD:-$(env_value SUPER_USER_PASSWORD)}
DB_NAME_VALUE=${DB_NAME:-$(env_value DB_NAME)}

if [ ! -f "$MINIO_CERT_DIR/public.crt" ] || [ ! -f "$MINIO_CERT_DIR/private.key" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$MINIO_CERT_DIR/private.key" \
        -out "$MINIO_CERT_DIR/public.crt" \
        -days 1 \
        -subj "/CN=minio" \
        -addext "subjectAltName=DNS:minio,DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
fi

cat > "$OVERRIDE_FILE" <<EOF
services:
  db:
    ports: !override
      - "127.0.0.1:${DB_PORT}:5432"
    environment:
      - S3_REGION=us-east-1
      - S3_ACCESS_KEY_ID=minioadmin
      - S3_SECRET_ACCESS_KEY=minioadmin
      - S3_BUCKET=yelukerest-backups
      - S3_ENDPOINT=minio
      - S3_PREFIX=pgbackrest
      - PGBACKREST_REPO1_S3_URI_STYLE=path
      - PGBACKREST_REPO1_STORAGE_PORT=9000
      - PGBACKREST_REPO1_STORAGE_VERIFY_TLS=n
      - POSTGRES_DATA_PATH=/var/lib/postgresql/18/docker
  backup:
    depends_on:
      db:
        condition: service_started
      minio-init:
        condition: service_completed_successfully
    environment:
      - SCHEDULE=**None**
      - S3_REGION=us-east-1
      - S3_ACCESS_KEY_ID=minioadmin
      - S3_SECRET_ACCESS_KEY=minioadmin
      - S3_BUCKET=yelukerest-backups
      - S3_ENDPOINT=minio
      - S3_PREFIX=pgbackrest
      - PGBACKREST_REPO1_S3_URI_STYLE=path
      - PGBACKREST_REPO1_STORAGE_PORT=9000
      - PGBACKREST_REPO1_STORAGE_VERIFY_TLS=n
      - POSTGRES_USER=\${SUPER_USER}
      - POSTGRES_PASSWORD=\${SUPER_USER_PASSWORD}
      - POSTGRES_PORT=5432
      - POSTGRES_DATA_PATH=/var/lib/postgresql/18/docker
      - POSTGRES_SOCKET_PATH=/var/run/postgresql
  minio:
    image: ${MINIO_IMAGE}
    command: server /data --address ":9000" --console-address ":9001"
    environment:
      - MINIO_ROOT_USER=minioadmin
      - MINIO_ROOT_PASSWORD=minioadmin
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"
    volumes:
      - ./tmp/pgbackrest-minio-certs:/root/.minio/certs:ro
  minio-init:
    image: ${MINIO_MC_IMAGE}
    depends_on:
      - minio
    entrypoint: /bin/sh
    command:
      - -ceu
      - |
        until mc --insecure alias set local https://minio:9000 minioadmin minioadmin; do sleep 1; done
        mc --insecure mb --ignore-existing local/yelukerest-backups
  minio-client:
    image: ${MINIO_MC_IMAGE}
    depends_on:
      - minio
    entrypoint: /bin/sh
EOF

compose() {
    PG_DATA_VOLUME_NAME=$PG_VOLUME_NAME \
    MAX_ROWS=${MAX_ROWS:-} \
    PRE_REQUEST=${PRE_REQUEST:-} \
    CADDY_LISTEN_HOST=${CADDY_LISTEN_HOST:-127.0.0.1} \
    CADDY_ACME_ACCESS_KEY_ID=${CADDY_ACME_ACCESS_KEY_ID:-} \
    CADDY_ACME_SECRET_ACCESS_KEY=${CADDY_ACME_SECRET_ACCESS_KEY:-} \
    CADDY_ACME_AWS_REGION=${CADDY_ACME_AWS_REGION:-} \
    ELMCLIENT_PIAZZA_URL=${ELMCLIENT_PIAZZA_URL:-} \
    ELMCLIENT_SLACK_URL=${ELMCLIENT_SLACK_URL:-} \
        docker compose \
        -p "$PROJECT_NAME" \
        -f docker-compose.base.yaml \
        -f docker-compose.prod.yaml \
        -f "$OVERRIDE_FILE" \
        "$@"
}

cleanup() {
    if [ -z "$KEEP_STACK" ]; then
        docker rm -f "$RESTORE_CONTAINER_NAME" >/dev/null 2>&1 || true
        compose down
        rm -f "$OVERRIDE_FILE"
        docker volume rm "$PG_VOLUME_NAME" >/dev/null 2>&1 || true
        docker volume rm "$RESTORE_VOLUME_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

restore_backup() {
    docker rm -f "$RESTORE_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run --rm \
        --network "${PROJECT_NAME}_default" \
        --entrypoint sh \
        -e S3_ACCESS_KEY_ID=minioadmin \
        -e S3_SECRET_ACCESS_KEY=minioadmin \
        -e S3_BUCKET=yelukerest-backups \
        -e S3_ENDPOINT=minio \
        -e S3_PREFIX=pgbackrest \
        -e S3_REGION=us-east-1 \
        -e PGBACKREST_REPO1_S3_URI_STYLE=path \
        -e PGBACKREST_REPO1_STORAGE_PORT=9000 \
        -e PGBACKREST_REPO1_STORAGE_VERIFY_TLS=n \
        -e POSTGRES_DATA_PATH=/var/lib/postgresql/18/docker \
        -v "${RESTORE_VOLUME_NAME}:/var/lib/postgresql" \
        yelukerest-postgres:18.4-pgbackrest \
        -ceu '
            rm -rf "$POSTGRES_DATA_PATH"
            mkdir -p "$POSTGRES_DATA_PATH"

            repo_path=/pgbackrest
            if [ -n "${S3_PREFIX:-}" ]; then
                repo_path="/${S3_PREFIX}"
            fi

            config=/var/lib/postgresql/pgbackrest-restore.conf

            cat > "$config" <<EOF
[global]
repo1-type=s3
repo1-path=${repo_path}
repo1-s3-bucket=${S3_BUCKET}
repo1-s3-key=${S3_ACCESS_KEY_ID}
repo1-s3-key-secret=${S3_SECRET_ACCESS_KEY}
repo1-s3-region=${S3_REGION}
repo1-s3-uri-style=${PGBACKREST_REPO1_S3_URI_STYLE}
repo1-storage-port=${PGBACKREST_REPO1_STORAGE_PORT}
repo1-storage-verify-tls=${PGBACKREST_REPO1_STORAGE_VERIFY_TLS}
log-level-console=info

[yelukerest]
pg1-path=${POSTGRES_DATA_PATH}
EOF

            repo1_endpoint=${S3_ENDPOINT:-}
            if [ -n "$repo1_endpoint" ] && [ "$repo1_endpoint" != "**None**" ]; then
                printf "repo1-s3-endpoint=%s\n" "$repo1_endpoint" >> "$config"
            fi

            pgbackrest --config="$config" --stanza=yelukerest restore
            chown -R postgres:postgres /var/lib/postgresql
        '
}

verify_restored_backup() {
    docker run -d \
        --name "$RESTORE_CONTAINER_NAME" \
        --network "${PROJECT_NAME}_default" \
        -e POSTGRES_USER="$SUPER_USER_VALUE" \
        -e POSTGRES_PASSWORD="$SUPER_USER_PASSWORD_VALUE" \
        -e POSTGRES_DB="$DB_NAME_VALUE" \
        -v "${RESTORE_VOLUME_NAME}:/var/lib/postgresql" \
        yelukerest-postgres:18.4-pgbackrest \
        postgres -c archive_mode=off >/dev/null

    for _ in $(seq 1 30); do
        if docker exec "$RESTORE_CONTAINER_NAME" pg_isready -U "$SUPER_USER_VALUE" -d "$DB_NAME_VALUE" >/dev/null 2>&1; then
            docker exec "$RESTORE_CONTAINER_NAME" psql -U "$SUPER_USER_VALUE" -d "$DB_NAME_VALUE" -tAc 'select 1' >/dev/null
            return 0
        fi
        sleep 1
    done

    docker logs "$RESTORE_CONTAINER_NAME" >&2 || true
    echo "Restored Postgres did not become ready." >&2
    return 1
}

compose build db backup
compose up -d db minio minio-init
# shellcheck disable=SC2016
compose exec -T db sh -ceu 'until pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do sleep 1; done'
compose run --rm backup
compose run --rm minio-client -ceu 'mc --insecure alias set local https://minio:9000 minioadmin minioadmin >/dev/null && mc --insecure stat local/yelukerest-backups/pgbackrest/backup/yelukerest/backup.info >/dev/null && mc --insecure stat local/yelukerest-backups/pgbackrest/archive/yelukerest/archive.info >/dev/null'
restore_backup
verify_restored_backup
