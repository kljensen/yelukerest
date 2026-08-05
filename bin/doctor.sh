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

check_hydra() {
    # Hydra (OAuth 2.1 authorization server, issue #270) checks. These
    # need the stack running; when it is not reachable we warn and skip
    # rather than fail, matching doctor's offline-friendly behavior.
    if ! command -v curl >/dev/null 2>&1; then
        warn "curl not available; skipping Hydra checks"
        return
    fi

    if [ "${DEVELOPMENT:-}" = "1" ]; then
        compose_files='-f docker-compose.base.yaml -f docker-compose.dev.yaml'
        hydra_base_url=${HYDRA_CHECK_URL:-https://localhost}
        curl_tls_flag='-k'
    else
        compose_files='-f docker-compose.base.yaml -f docker-compose.prod.yaml'
        hydra_base_url=${HYDRA_CHECK_URL:-https://${FQDN:-localhost}}
        curl_tls_flag=''
    fi

    # 1. Readiness, asked on the internal compose network (the health
    # endpoint is deliberately not routed through Caddy). The elmclient
    # container is used because the hydra and caddy images have no shell.
    # shellcheck disable=SC2086
    health=$(docker compose $compose_files exec -T elmclient \
        wget -qO- http://hydra:4444/health/ready 2>/dev/null || true)
    if [ -z "$health" ]; then
        warn "hydra /health/ready not reachable (is the stack up?); skipping remaining Hydra checks"
        return
    fi
    if printf '%s' "$health" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        ok "hydra /health/ready reports ok"
    else
        fail "hydra /health/ready returned unexpected payload: $health"
        return
    fi

    # 2. Both discovery documents are fetchable through Caddy and agree
    # on the issuer, which must match the expected public base URL.
    oidc_doc=$(curl -fsS $curl_tls_flag "$hydra_base_url/.well-known/openid-configuration" 2>/dev/null || true)
    oauth_doc=$(curl -fsS $curl_tls_flag "$hydra_base_url/.well-known/oauth-authorization-server" 2>/dev/null || true)
    if [ -z "$oidc_doc" ] || [ -z "$oauth_doc" ]; then
        fail "hydra discovery documents not fetchable from $hydra_base_url (.well-known/openid-configuration and .well-known/oauth-authorization-server)"
        return
    fi
    ok "hydra serves both well-known discovery documents"

    oidc_issuer=$(printf '%s' "$oidc_doc" | jq -r '.issuer // empty')
    oauth_issuer=$(printf '%s' "$oauth_doc" | jq -r '.issuer // empty')
    if [ "$oidc_issuer" = "$hydra_base_url" ] && [ "$oauth_issuer" = "$hydra_base_url" ]; then
        ok "hydra discovery issuers match $hydra_base_url"
    else
        fail "hydra discovery issuers inconsistent: openid-configuration=$oidc_issuer oauth-authorization-server=$oauth_issuer expected=$hydra_base_url"
    fi

    # 3. Dynamic Client Registration is enabled and advertised (MCP
    # clients find DCR through discovery).
    reg_endpoint=$(printf '%s' "$oidc_doc" | jq -r '.registration_endpoint // empty')
    if [ -n "$reg_endpoint" ]; then
        ok "hydra advertises registration_endpoint (DCR enabled): $reg_endpoint"
    else
        fail "hydra discovery lacks registration_endpoint; DCR is disabled or webfinger.oidc_discovery.client_registration_url is unset"
    fi

    if printf '%s' "$oauth_doc" | jq -e '.code_challenge_methods_supported | index("S256")' >/dev/null 2>&1; then
        ok "hydra advertises PKCE S256 support"
    else
        fail "hydra discovery lacks PKCE S256 support"
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

check_hydra

if [ "$failures" -ne 0 ]; then
    printf 'doctor failed: %d failure(s), %d warning(s)\n' "$failures" "$warnings" >&2
    exit 1
fi

printf 'doctor passed: %d warning(s)\n' "$warnings"
