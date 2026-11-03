#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

cd "$ROOT_DIR"

if [ -f "${ENV_FILE:-.env}" ]; then
    set -a
    . "${ENV_FILE:-.env}"
    set +a
fi

DB_PORT=${YELUKEREST_TEST_DB_PORT:-55432}
HTTP_PORT=${YELUKEREST_TEST_HTTP_PORT:-8080}
HTTPS_PORT=${YELUKEREST_TEST_HTTPS_PORT:-8443}
KEEP_STACK=${YELUKEREST_TEST_KEEP_STACK:-}
OVERRIDE_FILE=${YELUKEREST_TEST_COMPOSE_OVERRIDE:-tmp/docker-compose.test-rest-stack.yaml}

: "${YELUKEREST_TEST_MIGRATOR_DATABASE_URL:?YELUKEREST_TEST_MIGRATOR_DATABASE_URL is required}"
: "${YELUKEREST_TEST_DATABASE_URL:?YELUKEREST_TEST_DATABASE_URL is required}"
: "${DB_NAME:?DB_NAME is required}"

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

compose up -d --build --force-recreate db
# shellcheck disable=SC2016
compose exec -T db sh -ceu 'until pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do sleep 1; done'

PGHOST=127.0.0.1 \
PGPORT=$DB_PORT \
    ./bin/bootstrap-db.sh test-migrator

identity_sql="select current_database() || '|' || system_identifier from pg_control_system()"
migrator_identity=$(psql -X --tuples-only --no-align "$YELUKEREST_TEST_MIGRATOR_DATABASE_URL" \
    --command "$identity_sql")
test_identity=$(psql -X --tuples-only --no-align "$YELUKEREST_TEST_DATABASE_URL" \
    --command "$identity_sql")
if [ "$migrator_identity" != "$test_identity" ]; then
    echo 'YELUKEREST_TEST_MIGRATOR_DATABASE_URL and YELUKEREST_TEST_DATABASE_URL do not identify the same database.' >&2
    exit 1
fi

bootstrap_count=$(psql -X --tuples-only --no-align "$YELUKEREST_TEST_DATABASE_URL" \
    --command "select count(*) from zapadka.applied_migrations where slug = 'bootstrap-yelukerest'")
if [ "$bootstrap_count" != 1 ]; then
    echo 'YELUKEREST_TEST_DATABASE_URL is not the database Zapadka bootstrapped.' >&2
    exit 1
fi

compose up -d --build postgrest authapp elmclient caddy

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

# An extensionless file in the Elm client's build directory, so
# tests/rest/short_link_routing.js can show a real file wins over a
# same-named short link (issue #409). The client's next build clears it.
SHORT_LINK_STATIC_FILE=short-link-static-file
compose run --rm --no-deps -T --entrypoint sh elmclient -c \
    "printf 'static\n' > /opt/app/dist/$SHORT_LINK_STATIC_FILE"

TEST_BASE_URL=https://localhost:${HTTPS_PORT} \
DB_TEST_HOST=127.0.0.1 \
DB_TEST_PORT=$DB_PORT \
TEST_SHORT_LINK_STATIC_FILE=$SHORT_LINK_STATIC_FILE \
    bun run test_rest

compose run --rm --no-deps -T --entrypoint sh elmclient -c \
    "rm -f /opt/app/dist/$SHORT_LINK_STATIC_FILE"

# With PostgREST down a short link must fail as a 5xx, not as a 404 that a
# person or a cache would read as "no such link" (issue #409). Last, because
# it stops a service the suites above need.
compose stop postgrest
short_link_down=$(curl -k -sS -o /dev/null -D - -w 'status=%{http_code}\n' \
    "https://localhost:${HTTPS_PORT}/short-link-upstream-down" 2>/dev/null || true)
# Paths the matcher excludes never reach PostgREST, so they stay Caddy's 404
# even now; a 502 here would mean one was sent to the resolver.
excluded_down=""
for path in /rest /auth /cas /a/rnn /openapi /oauth2 /RNN /-rnn \
    /abbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; do
    code=$(curl -k -sS -o /dev/null -w '%{http_code}' "https://localhost:${HTTPS_PORT}${path}" 2>/dev/null || true)
    if [ "$code" != 404 ]; then
        excluded_down="$excluded_down $path=$code"
    fi
done
compose start postgrest
if [ -n "$excluded_down" ]; then
    echo "Excluded paths with PostgREST down did not answer 404:$excluded_down" >&2
    exit 1
fi
case "$short_link_down" in
    *status=5[0-9][0-9]*) ;;
    *)
        echo "A short link with PostgREST down did not answer 5xx:" >&2
        echo "$short_link_down" >&2
        exit 1
        ;;
esac
if ! printf '%s\n' "$short_link_down" | grep -qi '^cache-control: no-store'; then
    echo "A short link with PostgREST down was not sent Cache-Control: no-store:" >&2
    echo "$short_link_down" >&2
    exit 1
fi
echo "ok: a short link with PostgREST down answers $(printf '%s\n' "$short_link_down" | sed -n 's/^status=//p')"
