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
    # endpoint is deliberately not routed through Caddy). The hydra and caddy
    # images have no shell, so the probe borrows another service's image.
    #
    # `exec elmclient` was used here, but elmclient BUILDS the frontend and
    # exits, so in production it is always in the "exited" state and exec
    # always failed -- doctor then warned and returned, silently skipping every
    # remaining Hydra check. `run --rm` starts a fresh throwaway container, so
    # it works whether or not the service is currently up.
    # shellcheck disable=SC2086
    health=$(docker compose $compose_files run --rm --no-deps --entrypoint sh elmclient \
        -c 'wget -qO- http://hydra:4444/health/ready' 2>/dev/null || true)

    # Is the hydra container actually running? If it is, an unreachable health
    # endpoint is a real failure, not an "is the stack up?" warning.
    # shellcheck disable=SC2086
    hydra_state=$(docker compose $compose_files ps --format '{{.Service}}={{.State}}' 2>/dev/null \
        | grep '^hydra=' || true)

    if [ -z "$health" ]; then
        case "$hydra_state" in
            hydra=running)
                fail "hydra container is running but /health/ready is not reachable" ;;
            *)
                warn "hydra /health/ready not reachable and the hydra container is not running (is the stack up?)" ;;
        esac
    elif printf '%s' "$health" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        ok "hydra /health/ready reports ok"
    else
        fail "hydra /health/ready returned unexpected payload: $health"
    fi

    # Deliberately no `return` above: the checks below go through Caddy with
    # curl and are independent of the internal probe, so a failure here must not
    # hide an issuer mismatch or a missing registration endpoint.

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

check_hydra_client_count() {
    # Client-churn alert (issue #272): Claude Code registers a fresh
    # DCR client on every connection (anthropics/claude-code#59460), so
    # the registered-client count grows without bound unless
    # bin/prune-hydra-clients.sh runs. Warn when the count exceeds
    # HYDRA_CLIENT_COUNT_WARN (default 500, far above any realistic
    # enrollment). Counting uses the admin API from a neighbor
    # container because port 4445 is never proxied or published.
    threshold=${HYDRA_CLIENT_COUNT_WARN:-500}
    if [ "${DEVELOPMENT:-}" = "1" ]; then
        compose_files='-f docker-compose.base.yaml -f docker-compose.dev.yaml'
    else
        compose_files='-f docker-compose.base.yaml -f docker-compose.prod.yaml'
    fi

    body_file=$(mktemp)
    header_file=$(mktemp)
    count=0
    next='/admin/clients?page_size=500'
    pages=0
    while [ -n "$next" ] && [ "$pages" -lt 40 ]; do
        pages=$((pages + 1))
        # busybox wget prints response headers to stderr with -S; the
        # Link header there carries the opaque next-page token.
        # `run --rm` rather than `exec`: elmclient builds the frontend and
        # exits, so it is never running in production and exec always failed.
        # shellcheck disable=SC2086
        docker compose $compose_files run --rm --no-deps --entrypoint sh elmclient \
            -c "wget -SqO- 'http://hydra:4445$next'" >"$body_file" 2>"$header_file" || true
        page_count=$(jq 'if type == "array" then length else empty end' <"$body_file" 2>/dev/null || true)
        case "$page_count" in
            ''|*[!0-9]*)
                warn "hydra admin API not reachable for client count (is the stack up?); skipping"
                rm -f "$body_file" "$header_file"
                return
                ;;
        esac
        count=$((count + page_count))
        next=$(sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p' "$header_file" | head -n 1)
    done
    rm -f "$body_file" "$header_file"

    if [ "$count" -gt "$threshold" ]; then
        warn "hydra has $count registered OAuth clients (threshold $threshold); DCR churn is accumulating — run bin/prune-hydra-clients.sh (see docs/hydra.md)"
    else
        ok "hydra registered OAuth client count is $count (threshold $threshold)"
    fi
}

check_backup_fulls() {
    # Issue #341: backup.sh ran `pgbackrest backup` with no --type, so the
    # repository held exactly one full backup with every incremental chained to
    # it -- losing that single object would have invalidated every backup at
    # once. backup.sh now takes a full whenever the newest one is
    # BACKUP_FULL_INTERVAL_DAYS old; this confirms that happened in the
    # repository, not just in the script. The count comes from `backup.sh info`
    # so the S3 settings are the backup image's own, never a second copy here.
    #
    # The backup service is defined only in the production compose file and
    # needs the production data volume and S3 credentials, so anywhere else
    # this warns and skips rather than failing.
    if [ "${DEVELOPMENT:-}" = "1" ]; then
        warn "backup service is not part of the dev stack; skipping full-backup check"
        return
    fi

    if [ -z "${BACKUP_S3_BUCKET:-}" ]; then
        warn "BACKUP_S3_BUCKET is not set; skipping full-backup check"
        return
    fi

    # Mount the checked-out backup.sh over the image's copy. Without this the
    # probe runs whatever script is baked into the built image, and a backup
    # image predating the `info` mode ignores the argument and takes a REAL
    # backup -- a diagnostic that mutates the production repository and, worse,
    # can trigger an expire. Bind-mounting makes the running script the one we
    # are looking at, so an un-rebuilt image is harmless.
    backup_info=$(docker compose -f docker-compose.base.yaml -f docker-compose.prod.yaml \
        run --rm --no-deps \
        -v "$(pwd)/backup/backup.sh:/backup.sh:ro" \
        backup sh /backup.sh info 2>/dev/null || true)

    if ! printf '%s\n' "$backup_info" | grep -q '^stanza:'; then
        warn "pgbackrest info unavailable (needs the production host, its data volume, and S3 credentials); skipping full-backup check"
        return
    fi

    full_count=$(printf '%s\n' "$backup_info" | grep -c 'full backup:' || true)
    if [ "$full_count" -gt 1 ]; then
        ok "pgbackrest repository holds $full_count full backups"
    else
        warn "pgbackrest repository holds $full_count full backup; every incremental depends on that one object until the next full lands (see BACKUP_FULL_INTERVAL_DAYS and docs/backup-recovery.md)"
    fi
}

check_pending_migrations() {
    # Issue #357: production ran two migrations behind for weeks and doctor
    # said nothing, so data.user_api_token did not exist there and elmclient's
    # API-tokens page had never worked in production. Every other check here
    # asks about the running stack; none asked whether the database had been
    # given the schema the checked-out tree assumes. That drift only widens,
    # and it is invisible until someone runs `zapadka status` by hand.
    #
    # The target follows doctor's existing DEVELOPMENT convention, so this
    # asks about production on the production host and about the local
    # database when DEVELOPMENT=1.
    zapadka_bin=${ZAPADKA_BIN:-zapadka}
    if [ "${DEVELOPMENT:-}" = "1" ]; then
        migration_target=${ZAPADKA_TARGET:-development}
    else
        migration_target=${ZAPADKA_TARGET:-production}
    fi

    if ! command -v "$zapadka_bin" >/dev/null 2>&1; then
        warn "$zapadka_bin not available; cannot tell whether target $migration_target has pending migrations"
        return
    fi

    # --output json is a ReportV1 document that, unlike the human summary,
    # is documented not to vary with whether stdout is a terminal. -q keeps
    # progress off stderr; a nonzero exit still writes the report to stdout,
    # so the outcome is read from the document rather than from $?.
    report=$("$zapadka_bin" status --target "$migration_target" --output json -q 2>/dev/null || true)

    # Anything that is not a readable report means doctor could not tell.
    # Passing quietly here would reproduce exactly the silence this check
    # exists to end, so an unanswerable target fails rather than warns.
    if ! printf '%s' "$report" | jq -e '.report_version == 1' >/dev/null 2>&1; then
        fail "zapadka status --target $migration_target produced no ReportV1 document; cannot tell whether migrations are pending"
        return
    fi

    if ! printf '%s' "$report" | jq -e '.outcome == "success"' >/dev/null 2>&1; then
        reason=$(printf '%s' "$report" | jq -r '[.error.code, .error.message] | map(select(. != null)) | join(": ")')
        fail "zapadka status --target $migration_target did not complete ($reason); cannot tell whether migrations are pending"
        return
    fi

    # Anything not "applied" is drift between the graph and the registry, so
    # the status travels with each name instead of being assumed to be
    # "pending". The id is truncated to match zapadka's own human output.
    unapplied=$(printf '%s' "$report" | jq -r '
        [.migrations[]? | select(.status != "applied") | "\(.id[0:8]) \(.slug) (\(.status))"]
        | join(", ")')

    if [ -n "$unapplied" ]; then
        fail "target $migration_target is out of sync with the checked-out migration graph: $unapplied; deploy with ./bin/migrate.sh $migration_target"
    else
        applied_count=$(printf '%s' "$report" | jq -r '[.migrations[]?] | length')
        ok "target $migration_target has all $applied_count checked-out migrations applied"
    fi
}

check_checkout_freshness() {
    # The layer above check_pending_migrations: a host that never pulled has a
    # graph as old as its database, so migration status looks clean while the
    # repo has moved on. This warns rather than fails because deliberately
    # holding at a commit is legitimate, whereas an unapplied migration is not.
    #
    # ls-remote is one read-only round trip -- it neither fetches objects nor
    # moves refs -- and the -c/env settings below keep it from blocking on a
    # credential prompt or a dead network, which is what would otherwise make a
    # network call in doctor unsafe.
    #
    # This asks only about a deployed host. A developer is legitimately on a
    # feature branch, where "differs from origin/main" is the normal state, so
    # DEVELOPMENT skips it and pays no network cost.
    if [ "${DEVELOPMENT:-}" = "1" ]; then
        warn "a development checkout is expected to differ from origin/main; skipping freshness check"
        return
    fi

    if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
        warn "not a git checkout with git available; cannot tell whether this tree is behind origin/main"
        return
    fi

    head_commit=$(git rev-parse HEAD 2>/dev/null || true)

    # ConnectTimeout and the http low-speed settings bound the transfer but not
    # SSH auth, which has been seen to stall for a minute; timeout(1) is the
    # only hard ceiling. It is not POSIX, so its absence just means no ceiling
    # rather than no check.
    if command -v timeout >/dev/null 2>&1; then
        bounded='timeout 15'
    else
        bounded=''
    fi
    # shellcheck disable=SC2086
    remote_main=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' \
        $bounded git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
        ls-remote --heads origin main 2>/dev/null | awk 'NR==1 {print $1}')

    if [ -z "$head_commit" ] || [ -z "$remote_main" ]; then
        warn "origin/main not reachable; cannot tell whether this tree is behind it"
        return
    fi

    if [ "$head_commit" = "$remote_main" ]; then
        ok "checkout is at origin/main ($(printf '%.8s' "$head_commit"))"
    else
        warn "checkout is at $(printf '%.8s' "$head_commit") but origin/main is $(printf '%.8s' "$remote_main"); this tree may be missing code and migrations that exist on main"
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
check_hydra_client_count
check_backup_fulls
check_pending_migrations
check_checkout_freshness

if [ "$failures" -ne 0 ]; then
    printf 'doctor failed: %d failure(s), %d warning(s)\n' "$failures" "$warnings" >&2
    exit 1
fi

printf 'doctor passed: %d warning(s)\n' "$warnings"
