#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

DB_PORT=${YELUKEREST_TEST_DB_PORT:-55432}
HTTP_PORT=${YELUKEREST_TEST_HTTP_PORT:-8080}
HTTPS_PORT=${YELUKEREST_TEST_HTTPS_PORT:-8443}
KEEP_STACK=${YELUKEREST_TEST_KEEP_STACK:-}
OVERRIDE_FILE=${YELUKEREST_TEST_COMPOSE_OVERRIDE:-tmp/docker-compose.test-rest-stack.yaml}

cd "$ROOT_DIR"
mkdir -p "$(dirname "$OVERRIDE_FILE")"
TEST_AUTHAPP_JWT="$(./bin/jwt.sh '{"role":"app","app_name":"authapp"}')"
export TEST_AUTHAPP_JWT

cat > "$OVERRIDE_FILE" <<EOF
services:
  db:
    ports: !override
      - "127.0.0.1:${DB_PORT}:5432"
  caddy:
    ports: !override
      - "127.0.0.1:${HTTP_PORT}:80"
      - "127.0.0.1:${HTTPS_PORT}:443"
      - "127.0.0.1:${HTTPS_PORT}:443/udp"
EOF

compose() {
    AUTHAPP_JWT=$TEST_AUTHAPP_JWT \
    MAX_ROWS=${MAX_ROWS:-} \
    PRE_REQUEST=${PRE_REQUEST:-} \
    CADDY_LISTEN_HOST=${CADDY_LISTEN_HOST:-127.0.0.1} \
    CADDY_ACME_ACCESS_KEY_ID=${CADDY_ACME_ACCESS_KEY_ID:-} \
    CADDY_ACME_SECRET_ACCESS_KEY=${CADDY_ACME_SECRET_ACCESS_KEY:-} \
    CADDY_ACME_AWS_REGION=${CADDY_ACME_AWS_REGION:-} \
    ELMCLIENT_PIAZZA_URL=${ELMCLIENT_PIAZZA_URL:-} \
    ELMCLIENT_SLACK_URL=${ELMCLIENT_SLACK_URL:-} \
        docker compose -f docker-compose.base.yaml -f docker-compose.dev.yaml -f "$OVERRIDE_FILE" "$@"
}

cleanup() {
    if [ -z "$KEEP_STACK" ]; then
        compose down
        rm -f "$OVERRIDE_FILE"
    fi
}
trap cleanup EXIT INT TERM

compose up -d --build --force-recreate db postgrest authapp elmclient caddy
# shellcheck disable=SC2016
compose exec -T db sh -ceu 'until pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do sleep 1; done'

retries=30
while [ "$retries" -gt 0 ]; do
    status=$(curl -k -sS -o /dev/null -w '%{http_code}' "https://localhost:${HTTPS_PORT}/rest/" 2>/dev/null || true)
    if [ "$status" = "200" ]; then
        break
    fi
    retries=$((retries - 1))
    sleep 1
done

if [ "$status" != "200" ]; then
    echo "PostgREST did not become ready through Caddy; last HTTP status was ${status:-none}." >&2
    exit 1
fi

YELUKEREST_SMOKE_COMPOSE_EXTRA_FILE=$OVERRIDE_FILE \
YELUKEREST_SMOKE_BASE_URL=https://localhost:${HTTPS_PORT} \
YELUKEREST_SMOKE_HTTP_BASE_URL=http://localhost:${HTTP_PORT} \
YELUKEREST_SMOKE_SKIP_HTTP_REDIRECT=1 \
    ./bin/smoke.sh

DB_TEST_HOST=127.0.0.1 \
DB_TEST_PORT=$DB_PORT \
    bun run test_db

TEST_BASE_URL=https://localhost:${HTTPS_PORT} \
DB_TEST_HOST=127.0.0.1 \
DB_TEST_PORT=$DB_PORT \
    bun run test_rest
