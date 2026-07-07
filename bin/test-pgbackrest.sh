#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_NAME=${YELUKEREST_PGBACKREST_TEST_PROJECT:-yelukerest-pgbackrest-test}
DB_PORT=${YELUKEREST_PGBACKREST_TEST_DB_PORT:-55433}
PG_VOLUME_NAME=${YELUKEREST_PGBACKREST_TEST_PG_VOLUME:-${PROJECT_NAME}-pg-data}
OVERRIDE_FILE=${YELUKEREST_PGBACKREST_TEST_COMPOSE_OVERRIDE:-tmp/docker-compose.pgbackrest-test.yaml}
KEEP_STACK=${YELUKEREST_PGBACKREST_TEST_KEEP_STACK:-}
MINIO_CERT_DIR=tmp/pgbackrest-minio-certs
MINIO_IMAGE=${YELUKEREST_PGBACKREST_TEST_MINIO_IMAGE:-quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e}
MINIO_MC_IMAGE=${YELUKEREST_PGBACKREST_TEST_MINIO_MC_IMAGE:-quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727}

cd "$ROOT_DIR"
mkdir -p "$(dirname "$OVERRIDE_FILE")"
mkdir -p "$MINIO_CERT_DIR"
docker volume create "$PG_VOLUME_NAME" >/dev/null

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
    PG_DATA_VOLUME_NAME=$PG_VOLUME_NAME docker compose \
        -p "$PROJECT_NAME" \
        -f docker-compose.base.yaml \
        -f docker-compose.prod.yaml \
        -f "$OVERRIDE_FILE" \
        "$@"
}

cleanup() {
    if [ -z "$KEEP_STACK" ]; then
        compose down
        rm -f "$OVERRIDE_FILE"
        docker volume rm "$PG_VOLUME_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

compose up -d --build db minio minio-init
compose exec -T db sh -ceu 'until pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do sleep 1; done'
compose run --rm backup
compose run --rm minio-client -ceu 'mc --insecure alias set local https://minio:9000 minioadmin minioadmin >/dev/null && mc --insecure stat local/yelukerest-backups/pgbackrest/backup/yelukerest/backup.info >/dev/null'
