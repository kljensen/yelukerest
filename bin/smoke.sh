#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$ROOT_DIR/.env"
    set +a
fi

BASE_URL=${YELUKEREST_SMOKE_BASE_URL:-https://localhost}
HTTP_BASE_URL=${YELUKEREST_SMOKE_HTTP_BASE_URL:-http://localhost}
COMPOSE_BASE_FILE=${YELUKEREST_SMOKE_COMPOSE_BASE_FILE:-docker-compose.base.yaml}
COMPOSE_ENV_FILE=${YELUKEREST_SMOKE_COMPOSE_ENV_FILE:-docker-compose.dev.yaml}
COMPOSE_EXTRA_FILE=${YELUKEREST_SMOKE_COMPOSE_EXTRA_FILE:-}
SERVICES=${YELUKEREST_SMOKE_SERVICES:-"db postgrest authapp caddy"}
CURL_TIMEOUT=${YELUKEREST_SMOKE_CURL_TIMEOUT:-10}
FAILURES=0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yelukerest-smoke.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

BASE_URL=${BASE_URL%/}
HTTP_BASE_URL=${HTTP_BASE_URL%/}
INSECURE_TLS=${YELUKEREST_SMOKE_INSECURE_TLS:-}

if [ -z "$INSECURE_TLS" ]; then
    case "$BASE_URL" in
        https://localhost|https://localhost:*|https://127.0.0.1|https://127.0.0.1:*|https://host.docker.internal|https://host.docker.internal:*)
            INSECURE_TLS=1
            ;;
        *)
            INSECURE_TLS=0
            ;;
    esac
fi

say_ok() {
    printf 'ok - %s\n' "$1"
}

say_fail() {
    printf 'not ok - %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        say_fail "missing required command: $1"
        return 1
    fi
    return 0
}

compose() {
    if [ -n "$COMPOSE_EXTRA_FILE" ]; then
        docker compose -f "$COMPOSE_BASE_FILE" -f "$COMPOSE_ENV_FILE" -f "$COMPOSE_EXTRA_FILE" "$@"
    else
        docker compose -f "$COMPOSE_BASE_FILE" -f "$COMPOSE_ENV_FILE" "$@"
    fi
}

check_compose_file() {
    file=$1
    if [ -f "$ROOT_DIR/$file" ]; then
        say_ok "compose file exists: $file"
    else
        say_fail "compose file is missing: $file"
    fi
}

check_service() {
    service=$1
    ids=$(compose ps -a -q "$service" 2>/dev/null || true)

    if [ -z "$ids" ]; then
        say_fail "compose service '$service' has no container"
        return
    fi

    for id in $ids; do
        running=$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || true)

        if [ "$running" != "true" ]; then
            say_fail "compose service '$service' container $id is not running"
            continue
        fi

        if [ "$health" = "unhealthy" ]; then
            say_fail "compose service '$service' container $id is unhealthy"
            continue
        fi

        say_ok "compose service '$service' is running"
    done
}

curl_request() {
    url=$1
    body_file=$2
    header_file=$3
    err_file=$4

    if [ "$INSECURE_TLS" = "1" ]; then
        curl -k -sS \
            --connect-timeout "$CURL_TIMEOUT" \
            --max-time "$CURL_TIMEOUT" \
            -D "$header_file" \
            -o "$body_file" \
            -w '%{http_code}' \
            "$url" \
            2>"$err_file" || true
    else
        curl -sS \
            --connect-timeout "$CURL_TIMEOUT" \
            --max-time "$CURL_TIMEOUT" \
            -D "$header_file" \
            -o "$body_file" \
            -w '%{http_code}' \
            "$url" \
            2>"$err_file" || true
    fi
}

check_http() {
    name=$1
    url=$2
    expected_status=$3
    body_pattern=${4:-}

    safe_name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_' '_')
    body_file="$TMP_DIR/$safe_name.body"
    header_file="$TMP_DIR/$safe_name.headers"
    err_file="$TMP_DIR/$safe_name.err"

    status=$(curl_request "$url" "$body_file" "$header_file" "$err_file")

    if [ "$status" != "$expected_status" ]; then
        detail=$(cat "$err_file")
        if [ -n "$detail" ]; then
            say_fail "$name returned HTTP $status, expected $expected_status ($detail)"
        else
            say_fail "$name returned HTTP $status, expected $expected_status"
        fi
        return
    fi

    if [ -n "$body_pattern" ] && ! grep -E "$body_pattern" "$body_file" >/dev/null 2>&1; then
        say_fail "$name returned HTTP $status but response did not match '$body_pattern'"
        return
    fi

    say_ok "$name returned HTTP $expected_status"
}

check_db() {
    if [ -z "${SUPER_USER:-}" ] || [ -z "${DB_NAME:-}" ]; then
        say_fail "database readiness check needs SUPER_USER and DB_NAME from .env"
        return
    fi

    if compose exec -T db pg_isready -U "$SUPER_USER" -d "$DB_NAME" >/dev/null 2>&1; then
        say_ok "database accepts connections"
    else
        say_fail "database readiness check failed"
    fi
}

main() {
    cd "$ROOT_DIR"

    require_command docker || true
    require_command curl || true

    if [ "$FAILURES" -ne 0 ]; then
        exit "$FAILURES"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        say_fail "docker compose is not available"
        exit "$FAILURES"
    fi

    check_compose_file "$COMPOSE_BASE_FILE"
    check_compose_file "$COMPOSE_ENV_FILE"
    if [ -n "$COMPOSE_EXTRA_FILE" ]; then
        check_compose_file "$COMPOSE_EXTRA_FILE"
    fi

    for service in $SERVICES; do
        check_service "$service"
    done

    check_db

    if [ "${YELUKEREST_SMOKE_SKIP_HTTP_REDIRECT:-}" = "" ]; then
        check_http "plain HTTP redirects to HTTPS" "$HTTP_BASE_URL/rest/" "308"
    fi

    check_http "frontend shell" "$BASE_URL/" "200" '<div id="main"'
    check_http "OpenAPI UI" "$BASE_URL/openapi/" "200" 'swagger-ui'
    check_http "PostgREST root OpenAPI JSON" "$BASE_URL/rest/" "200" '"(swagger|openapi)"[[:space:]]*:'
    check_http "anonymous DB-backed meetings endpoint" "$BASE_URL/rest/meetings?select=slug&limit=1" "200" '^\['
    check_http "authapp unauthenticated /auth/me" "$BASE_URL/auth/me" "401" 'Unauthorized'

    if [ "$FAILURES" -ne 0 ]; then
        printf '\nSmoke test failed with %s failure(s).\n' "$FAILURES" >&2
        exit "$FAILURES"
    fi

    printf '\nSmoke test passed.\n'
}

main "$@"
