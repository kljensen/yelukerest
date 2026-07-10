#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

failures=0
warnings=0
env_authapp_jwt=${AUTHAPP_JWT+x}
env_authapp_jwt_value=${AUTHAPP_JWT:-}
env_jwt_secret=${JWT_SECRET+x}
env_jwt_secret_value=${JWT_SECRET:-}
env_jwt_issuer=${JWT_ISSUER+x}
env_jwt_issuer_value=${JWT_ISSUER:-}
env_jwt_audience=${JWT_AUDIENCE+x}
env_jwt_audience_value=${JWT_AUDIENCE:-}
env_pre_request=${PRE_REQUEST+x}
env_pre_request_value=${PRE_REQUEST:-}

ok() {
    printf 'ok - %s\n' "$1"
}

warn() {
    warnings=$((warnings + 1))
    printf 'warn - %s\n' "$1" >&2
}

fail() {
    failures=$((failures + 1))
    printf 'fail - %s\n' "$1" >&2
}

need_command() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 is available"
    else
        fail "$1 is required"
    fi
}

env_or_empty() {
    eval "printf '%s' \"\${$1:-}\""
}

decode_jwt_payload() {
    token=$1
    segment=$(printf '%s' "$token" | awk -F. '{print $2}')
    if [ -z "$segment" ]; then
        return 1
    fi

    base64_payload=$(printf '%s' "$segment" | tr '_-' '/+')
    remainder=$((${#base64_payload} % 4))
    if [ "$remainder" -eq 2 ]; then
        base64_payload="${base64_payload}=="
    elif [ "$remainder" -eq 3 ]; then
        base64_payload="${base64_payload}="
    elif [ "$remainder" -ne 0 ]; then
        return 1
    fi

    printf '%s' "$base64_payload" | openssl enc -base64 -d -A
}

check_authapp_jwt() {
    token=$(env_or_empty AUTHAPP_JWT)
    if [ -z "$token" ]; then
        fail "AUTHAPP_JWT is not set"
        return
    fi

    dot_count=$(printf '%s' "$token" | tr -cd '.' | wc -c | tr -d ' ')
    if [ "$dot_count" != "2" ]; then
        fail "AUTHAPP_JWT must have three JWT segments"
        return
    fi

    if ! payload=$(decode_jwt_payload "$token"); then
        fail "AUTHAPP_JWT payload could not be decoded"
        return
    fi

    issuer=${JWT_ISSUER:-yelukerest}
    audience=${JWT_AUDIENCE:-yelukerest-postgrest}
    now=$(date +%s)

    if printf '%s' "$payload" | jq -e --arg issuer "$issuer" --arg audience "$audience" '
        .iss == $issuer
        and ((.aud == $audience) or ((.aud | type) == "array" and (.aud | index($audience))))
        and .sub == "app:authapp"
        and .role == "app"
        and .app_name == "authapp"
        and (.iat | type) == "number"
        and (.nbf | type) == "number"
        and (.exp | type) == "number"
    ' >/dev/null; then
        ok "AUTHAPP_JWT has the expected authapp claims"
    else
        fail "AUTHAPP_JWT is missing required authapp claims; regenerate it with ./bin/jwt.sh '{\"role\":\"app\",\"app_name\":\"authapp\"}'"
        return
    fi

    exp=$(printf '%s' "$payload" | jq -r '.exp')
    if [ "$exp" -le "$now" ]; then
        fail "AUTHAPP_JWT is expired"
    else
        ok "AUTHAPP_JWT is not expired"
    fi
}

need_command jq
need_command openssl

if [ -f .env ]; then
    set -a
    . ./.env
    set +a
    if [ -n "$env_authapp_jwt" ]; then AUTHAPP_JWT=$env_authapp_jwt_value; fi
    if [ -n "$env_jwt_secret" ]; then JWT_SECRET=$env_jwt_secret_value; fi
    if [ -n "$env_jwt_issuer" ]; then JWT_ISSUER=$env_jwt_issuer_value; fi
    if [ -n "$env_jwt_audience" ]; then JWT_AUDIENCE=$env_jwt_audience_value; fi
    if [ -n "$env_pre_request" ]; then PRE_REQUEST=$env_pre_request_value; fi
    ok ".env loaded"
else
    warn ".env not found; checking exported environment only"
fi

jwt_secret=$(env_or_empty JWT_SECRET)
if [ -z "$jwt_secret" ]; then
    fail "JWT_SECRET is not set"
elif [ "${#jwt_secret}" -lt 32 ]; then
    fail "JWT_SECRET must be at least 32 characters for PostgREST"
elif [ "${#jwt_secret}" -lt 64 ]; then
    warn "JWT_SECRET is at least 32 characters, but 64+ random characters is preferred"
else
    ok "JWT_SECRET length is strong"
fi

check_authapp_jwt

if grep -q 'PGRST_DB_PRE_REQUEST=${PRE_REQUEST:-api.check_request_jwt}' docker-compose.base.yaml; then
    ok "PostgREST pre-request hook defaults to api.check_request_jwt"
else
    fail "PostgREST pre-request hook does not default to api.check_request_jwt"
fi

if [ -n "${PRE_REQUEST:-}" ] && [ "$PRE_REQUEST" != "api.check_request_jwt" ]; then
    warn "PRE_REQUEST overrides the secure default: $PRE_REQUEST"
fi

if [ "$failures" -ne 0 ]; then
    printf 'doctor failed: %d failure(s), %d warning(s)\n' "$failures" "$warnings" >&2
    exit 1
fi

printf 'doctor passed: %d warning(s)\n' "$warnings"
