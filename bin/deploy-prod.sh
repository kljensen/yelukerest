#!/bin/sh
# Deploy migrations to production, from here, in one command.
#
# WHY THIS EXISTS
#
# Everything in bin/ assumes it is already running on the production host:
# prod.sh shells out to `docker compose`, migrate.sh runs `zapadka deploy`
# against a target whose connection details only exist there. So deploying has
# meant remembering to ssh in, remembering to pull, remembering which zapadka
# invocation, and remembering to verify afterwards. Four things to remember is
# three too many for something done in a hurry, mid-term.
#
# zapadka.toml declares [targets.production] with pg_service
# "yelukerest-production". No laptop has that service defined, and it should
# stay that way: pointing it at a tunnel means the production superuser
# password has to live on the laptop too. The database is reachable only on
# 127.0.0.1 on the server, where zapadka is installed and the credentials
# already are. So this script does not bring production to you -- it runs the
# same commands you would have typed, on the box, over ssh.
#
# Read-only by default. It shows you what is pending and stops; --deploy is
# what actually changes anything.

set -eu

HOST="${YELUKEREST_PROD_HOST:-www.656.mba}"
DIR="${YELUKEREST_PROD_DIR:-yelukerest}"
REF="${YELUKEREST_PROD_REF:-origin/main}"
DEPLOY=""
SERVICES=""

usage () {
    cat >&2 <<USAGE
usage: $0 [--deploy] [--services "a b c"] [--host HOST] [--ref REF]

  (no flags)  fetch, report what is pending, change nothing
  --deploy    also apply the pending migrations, then verify

  --services  after migrating, rebuild and restart these compose services.
              Requires --deploy. Go services need the image rebuilt; the Elm
              client bind-mounts its source and rebuilds on start, so a
              recreate is enough for it. This does both, which is correct for
              either.

  --host      production host (default $HOST, or YELUKEREST_PROD_HOST)
  --ref       git ref to deploy (default $REF, or YELUKEREST_PROD_REF)
USAGE
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --deploy) DEPLOY=1; shift ;;
        --services) SERVICES="${2:?--services needs a value}"; shift 2 ;;
        --host)   HOST="${2:?--host needs a value}"; shift 2 ;;
        --ref)    REF="${2:?--ref needs a value}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

# The server pulls from the remote, so anything only on this laptop cannot be
# deployed. Catching that here turns a confusing "0 pending" into an answer.
if ! git diff --quiet HEAD 2>/dev/null; then
    echo "Refusing: you have uncommitted changes. Commit them first." >&2
    exit 1
fi
# Ask the remote, rather than trust refs/remotes. A push made with an explicit
# URL -- which is how these get pushed when the ssh agent is locked -- never
# updates the local tracking ref, so origin/main here can be many commits stale
# while the remote is perfectly up to date. Comparing against it would refuse
# deploys that are fine, and, worse, would pass one that is not.
local_head=$(git rev-parse HEAD)
remote_branch=${REF#origin/}
remote_head=$(git ls-remote origin "$remote_branch" 2>/dev/null | awk 'NR==1 {print $1}')
if [ -z "$remote_head" ]; then
    echo "Refusing: could not ask origin for '$remote_branch'." >&2
    exit 1
fi
if [ "$local_head" != "$remote_head" ]; then
    echo "Refusing: what you have checked out is not what would be deployed." >&2
    echo "  your HEAD:        $(git rev-parse --short HEAD)  $(git log -1 --format=%s)" >&2
    echo "  origin/$remote_branch: $(echo "$remote_head" | cut -c1-7)" >&2
    echo >&2
    echo "Push your work, or pass --ref to deploy something else deliberately." >&2
    exit 1
fi

echo "==> $HOST:$DIR  ->  $REF"

# One ssh, one shell, so a failure part-way cannot leave the checkout moved
# but the migration unapplied. `checkout --detach` matches how the server
# already sits (detached, not on a branch) and never invents a merge.
if [ -n "$SERVICES" ] && [ -z "${DEPLOY:-}" ]; then
    echo "Refusing: --services without --deploy. A read-only run changes nothing." >&2
    exit 1
fi

ssh "$HOST" DIR="$DIR" REF="$REF" DEPLOY="${DEPLOY:-}" SERVICES="$SERVICES" 'sh -s' <<'REMOTE'
set -eu
cd "$DIR"

if ! git diff --quiet HEAD; then
    echo "Refusing: the checkout on this host has uncommitted changes." >&2
    git status --short >&2
    exit 1
fi

git fetch --quiet origin
echo "    was: $(git rev-parse --short HEAD)"
git checkout --quiet --detach "$REF"
echo "    now: $(git rev-parse --short HEAD)  $(git log -1 --format=%s)"

echo
zapadka status --target production

if [ -z "${DEPLOY:-}" ]; then
    echo
    echo "Read-only run. Re-run with --deploy to apply the above."
    exit 0
fi

echo
zapadka deploy --target production
echo
zapadka verify --target production

if [ -n "${SERVICES:-}" ]; then
    echo
    echo "==> rebuilding: $SERVICES"
    # --build for the services whose source is baked into an image, and
    # --force-recreate because a service whose only change is a bind-mounted
    # file or an environment variable is otherwise a no-op: `up -d` compares
    # image and config, and neither moved.
    ./bin/prod.sh up -d --build --force-recreate $SERVICES
    echo
    ./bin/prod.sh ps $SERVICES
fi
REMOTE
