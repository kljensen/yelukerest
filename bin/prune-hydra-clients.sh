#!/usr/bin/env sh
# Prune stale Hydra OAuth clients created by DCR churn (issue #272).
#
# Claude Code registers a fresh DCR client on every connection
# (anthropics/claude-code#59460), orphaning old clients and their
# refresh tokens; over a semester the client table grows without bound.
# This script deletes clients that are BOTH:
#   - older than N days (created_at AND updated_at; default 30, which
#     matches the refresh-token TTL in hydra/hydra.yml), and
#   - not referenced by any active consent session of any known subject
#     (checked via the Hydra admin REST API, per app-user subject).
#
# It is conservative by default:
#   - dry run unless --yes is given;
#   - only public clients (token_endpoint_auth_method "none", the DCR
#     churn population) are considered unless --include-confidential;
#   - if the subject list cannot be read from the app database, the
#     script aborts rather than guess.
#
# The admin API (port 4445) is never proxied or published, so all
# access goes through neighbor containers: busybox wget in elmclient
# for reads, and the hydra CLI in the hydra container for deletes
# (busybox wget cannot send DELETE). See docs/hydra.md.
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

usage() {
    cat <<'EOF'
Usage: bin/prune-hydra-clients.sh [--days N] [--yes] [--include-confidential]

Delete Hydra OAuth clients older than N days (default 30) that have no
active consent sessions. Dry run by default; pass --yes to delete.

Options:
  --days N                 Age threshold in days (default 30). Keep this
                           >= the refresh-token TTL (30 days) so clients
                           with unexpired refresh tokens are not pruned.
  --yes                    Actually delete; otherwise print candidates.
  --include-confidential   Also consider clients with a client secret
                           (default: only public/DCR clients).
  -h, --help               Show this help.

Environment: DEVELOPMENT=1 selects the dev compose files.
EOF
}

days=30
apply=0
include_confidential=0
while [ $# -gt 0 ]; do
    case "$1" in
        --days)
            shift
            days=${1:-}
            case "$days" in
                ''|*[!0-9]*) echo "error: --days requires a positive integer" >&2; exit 2;;
            esac
            ;;
        --yes) apply=1;;
        --include-confidential) include_confidential=1;;
        -h|--help) usage; exit 0;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2;;
    esac
    shift
done

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required" >&2
    exit 1
fi

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

if [ "${DEVELOPMENT:-}" = "1" ]; then
    compose_files='-f docker-compose.base.yaml -f docker-compose.dev.yaml'
else
    compose_files='-f docker-compose.base.yaml -f docker-compose.prod.yaml'
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

admin_get() {
    # $1: admin API path (starting with /). Body on stdout, response
    # headers into $workdir/headers (busybox wget -S prints them to
    # stderr).
    # shellcheck disable=SC2086
    docker compose $compose_files exec -T elmclient \
        wget -SqO- "http://hydra:4445$1" 2>"$workdir/headers"
}

# 1. Fetch every registered client (paginated; opaque next-page token
# arrives in the Link response header).
: >"$workdir/clients-pages"
next='/admin/clients?page_size=500'
pages=0
while [ -n "$next" ] && [ "$pages" -lt 40 ]; do
    pages=$((pages + 1))
    if ! admin_get "$next" >"$workdir/page"; then
        echo "error: hydra admin API not reachable (is the stack up?)" >&2
        exit 1
    fi
    if ! jq -e 'type == "array"' <"$workdir/page" >/dev/null 2>&1; then
        echo "error: unexpected response from hydra admin API:" >&2
        head -c 300 "$workdir/page" >&2
        exit 1
    fi
    cat "$workdir/page" >>"$workdir/clients-pages"
    next=$(sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p' "$workdir/headers" | head -n 1)
done
jq -s 'add' "$workdir/clients-pages" >"$workdir/clients.json"
total=$(jq 'length' "$workdir/clients.json")

# 2. Collect the client ids referenced by active consent sessions. The
# admin consent-session listing requires a subject, so enumerate every
# possible subject from the app database (netid and numeric id cover
# both subject formats authapp might issue).
if ! subjects=$(
    # shellcheck disable=SC2086
    docker compose $compose_files exec -T db \
        psql -U "${SUPER_USER:?SUPER_USER must be set (source .env)}" \
        -d "${DB_NAME:?DB_NAME must be set (source .env)}" \
        -tAc 'select netid from data."user" union select id::text from data."user"'
); then
    echo "error: could not enumerate subjects from the app database; refusing to prune blind" >&2
    exit 1
fi

: >"$workdir/used-ids"
for subject in $subjects; do
    # Consent listings are paginated too: reading only the first page
    # would mark clients on later pages as unused and delete them.
    consent_next="/admin/oauth2/auth/sessions/consent?subject=$subject&page_size=500"
    consent_pages=0
    while [ -n "$consent_next" ] && [ "$consent_pages" -lt 40 ]; do
        consent_pages=$((consent_pages + 1))
        if ! admin_get "$consent_next" >"$workdir/consent"; then
            echo "error: could not list consent sessions for a subject; refusing to prune blind" >&2
            exit 1
        fi
        jq -r '.[]? | (.consent_request.client.client_id? // empty)' <"$workdir/consent" >>"$workdir/used-ids"
        consent_next=$(sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p' "$workdir/headers" | head -n 1)
    done
    if [ "$consent_pages" -ge 40 ]; then
        echo "error: consent session listing did not terminate; refusing to prune blind" >&2
        exit 1
    fi
done
jq -R . "$workdir/used-ids" | jq -s 'unique' >"$workdir/used.json"

# 3. Select candidates: old (created_at AND updated_at before the
# cutoff), unused, and (by default) public clients only.
cutoff=$(( $(date -u +%s) - days * 86400 ))
jq \
    --argjson cutoff "$cutoff" \
    --argjson used "$(cat "$workdir/used.json")" \
    --argjson confidential "$include_confidential" \
    '
    def epoch: sub("\\.[0-9]+"; "") | fromdateiso8601;
    [ .[]
      | select(.created_at != null and (.created_at | epoch) < $cutoff)
      | select((.updated_at // .created_at | epoch) < $cutoff)
      | .client_id as $id | select(($used | index($id)) | not)
      | select($confidential == 1 or .token_endpoint_auth_method == "none")
    ]' "$workdir/clients.json" >"$workdir/candidates.json"

candidate_count=$(jq 'length' "$workdir/candidates.json")
used_count=$(jq 'length' "$workdir/used.json")
echo "registered clients: $total; with active consent sessions: $used_count; prune candidates (idle > $days days): $candidate_count"

if [ "$candidate_count" -eq 0 ]; then
    echo "nothing to prune"
    exit 0
fi

jq -r '.[] | [.client_id, (.client_name // "-"), .created_at] | @tsv' "$workdir/candidates.json" |
    while IFS="$(printf '\t')" read -r client_id client_name created_at; do
        printf '  %s  created=%s  name=%s\n' "$client_id" "$created_at" "$client_name"
    done

if [ "$apply" -ne 1 ]; then
    echo "dry run: no clients deleted; re-run with --yes to delete the $candidate_count client(s) above"
    exit 0
fi

deleted=0
# Read line by line: command substitution would word-split and glob-expand
# client ids that contain whitespace or glob characters.
jq -r '.[].client_id' "$workdir/candidates.json" >"$workdir/candidate-ids"
while IFS= read -r client_id; do
    [ -n "$client_id" ] || continue
    # busybox wget cannot send DELETE, so use the hydra CLI that ships
    # in the hydra container (image has no shell, binary is on PATH).
    # shellcheck disable=SC2086
    if docker compose $compose_files exec -T hydra \
        hydra delete oauth2-client "$client_id" --endpoint http://127.0.0.1:4445 >/dev/null; then
        deleted=$((deleted + 1))
        echo "deleted $client_id"
    else
        echo "warning: failed to delete $client_id" >&2
    fi
done <"$workdir/candidate-ids"
echo "deleted $deleted of $candidate_count candidate client(s)"
