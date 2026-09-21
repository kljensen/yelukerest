#!/bin/sh
# Runs the provisioning integration suite (issue #398) against the running
# dev stack:
#
#   1. starts the fake GitHub (tests/fake-github/server.js) on the host,
#   2. rebuilds authapp from this checkout and restarts it with provisioning
#      enabled and pointed at the fake through host.docker.internal,
#   3. runs `bun test tests/provisioning/lifecycle.js` (named, not globbed:
#      demo.js in the same directory is a seed script, and `bun test` runs
#      any file it is handed),
#   4. runs the page script's own unit test, `bun run test_authapp_static`,
#      which needs no stack at all but belongs with the rest of the
#      repositories page's checks,
#   5. stops the fake and restarts authapp without the provisioning
#      variables, so the stack is left as `./bin/dev.sh up` leaves it.
#
# The fake's token is a placeholder, not a credential, and lives here rather
# than in .env: nothing in .env should ever enable provisioning by accident.
# For the same reason the test container gets every other GITHUB_* variable
# blanked explicitly, whatever .env says, and the cleanup restarts authapp
# with .env's own values again.
#
# Like test_db and test_rest, the suite resets the shared dev database's
# sample data. Set YELUKEREST_TEST_KEEP_FAKE=1 to leave the fake and authapp
# configured afterwards, for poking at a failure by hand.
#
# The fake's pid is written to tests/provisioning/.fake.pid (ignored by
# git). A later run finds a live pid there and adopts that fake instead of
# starting a second one, which is how a run after YELUKEREST_TEST_KEEP_FAKE
# works; a port that is busy with no live pid of ours is somebody else's
# listener, and the run stops rather than test against it.
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

if [ -f "${ENV_FILE:-.env}" ]; then
    set -a
    . "${ENV_FILE:-.env}"
    set +a
fi

FAKE_GITHUB_PORT=${FAKE_GITHUB_PORT:-4099}
FAKE_GITHUB_TOKEN=${FAKE_GITHUB_TOKEN:-fake-token}
FAKE_GITHUB_URL="http://127.0.0.1:${FAKE_GITHUB_PORT}"
KEEP_FAKE=${YELUKEREST_TEST_KEEP_FAKE:-}
READY_TIMEOUT=${YELUKEREST_TEST_READY_TIMEOUT:-30}

# Where the fake listens. On Docker Desktop, host.docker.internal reaches a
# server bound to the host's loopback; on Linux the host-gateway address is
# the host's bridge address, which loopback does not answer, so the fake
# binds every interface there. It refuses any request without the token.
case "$(uname -s)" in
    Linux) FAKE_GITHUB_BIND=${FAKE_GITHUB_BIND:-0.0.0.0} ;;
    *) FAKE_GITHUB_BIND=${FAKE_GITHUB_BIND:-127.0.0.1} ;;
esac

compose() {
    docker compose -f docker-compose.base.yaml -f docker-compose.dev.yaml "$@"
}

# authapp with provisioning on, talking to the fake through
# host.docker.internal. Every other provisioner and join variable is set
# empty for the run so a .env that carries an App or a join App cannot make
# authapp refuse to start (both credentials set) or reach a real GitHub.
authapp_with_fake() {
    GITHUB_PROVISIONER_ORG=course-org \
    GITHUB_PROVISIONER_STUDENTS_TEAM_SLUG=students \
    GITHUB_PROVISIONER_TOKEN="$FAKE_GITHUB_TOKEN" \
    GITHUB_PROVISIONER_API_BASE_URL="http://host.docker.internal:${FAKE_GITHUB_PORT}" \
    GITHUB_PROVISIONER_APP_ID= \
    GITHUB_PROVISIONER_INSTALLATION_ID= \
    GITHUB_PROVISIONER_PRIVATE_KEY_FILE= \
    GITHUB_JOIN_APP_CLIENT_ID= \
    GITHUB_JOIN_APP_CLIENT_SECRET= \
    GITHUB_JOIN_APP_AUTHORIZE_URL= \
    GITHUB_JOIN_APP_TOKEN_URL= \
    GITHUB_JOIN_APP_API_BASE_URL= \
        compose up -d --no-deps authapp
}

# authapp as the dev stack normally runs it. The variables above were
# exported from .env at the top of this script, so Compose interpolates
# .env's own values (empty by default, which disables provisioning) back
# into the container.
authapp_without_fake() {
    compose up -d --no-deps --force-recreate authapp
}

# Waits up to READY_TIMEOUT seconds for a probe to succeed; the message
# names what did not come up. While waiting for the fake, its process
# having exited is answered at once rather than at the timeout.
wait_for() {
    what=$1; shift
    i=0
    until "$@" >/dev/null 2>&1; do
        if [ -n "$FAKE_PID" ] && ! kill -0 "$FAKE_PID" 2>/dev/null; then
            echo "the fake GitHub (pid $FAKE_PID) is not running" >&2
            return 1
        fi
        i=$((i + 1))
        if [ "$i" -ge "$READY_TIMEOUT" ]; then
            echo "$what did not come up within ${READY_TIMEOUT}s" >&2
            return 1
        fi
        sleep 1
    done
}

authapp_answers_login() {
    curl -ksS -o /dev/null -w '%{http_code}' https://localhost/auth/login | grep -q '^30'
}

FAKE_PIDFILE=tests/provisioning/.fake.pid
FAKE_PID=
cleanup() {
    status=$?
    if [ -n "$KEEP_FAKE" ]; then
        echo "leaving the fake GitHub (pid $FAKE_PID, recorded in $FAKE_PIDFILE) and authapp configured; YELUKEREST_TEST_KEEP_FAKE is set" >&2
        echo "to undo: kill \$(cat $FAKE_PIDFILE); rm $FAKE_PIDFILE; ./bin/dev.sh up -d --force-recreate authapp" >&2
        exit $status
    fi
    if [ -n "$FAKE_PID" ]; then
        kill "$FAKE_PID" 2>/dev/null || true
        rm -f "$FAKE_PIDFILE"
    fi
    authapp_without_fake >/dev/null 2>&1 || echo "could not restart authapp without provisioning; run ./bin/dev.sh up -d --force-recreate authapp" >&2
    exit $status
}

# Something answers on the fake's port. curl's exit status 7 is "connection
# refused", which is the only answer that means free; anything else,
# including a listener that answers slowly or with an error, means busy.
port_is_busy() {
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${FAKE_GITHUB_PORT}/" >/dev/null 2>&1
    [ $? -ne 7 ]
}

# Health, and the process it is expected from: a health answer from a pid
# that is gone would be some other listener's.
fake_is_up() {
    kill -0 "$FAKE_PID" 2>/dev/null && curl -fsS "$FAKE_GITHUB_URL/__fake/health" >/dev/null 2>&1
}

if [ -f "$FAKE_PIDFILE" ] && kill -0 "$(cat "$FAKE_PIDFILE")" 2>/dev/null; then
    FAKE_PID=$(cat "$FAKE_PIDFILE")
    echo "adopting the fake GitHub already running as pid $FAKE_PID ($FAKE_PIDFILE)" >&2
else
    rm -f "$FAKE_PIDFILE"
    if port_is_busy; then
        echo "port $FAKE_GITHUB_PORT is in use and $FAKE_PIDFILE names no live process; it is not our fake." >&2
        echo "stop that listener first (lsof -nP -iTCP:$FAKE_GITHUB_PORT -sTCP:LISTEN, then kill it) or set FAKE_GITHUB_PORT." >&2
        exit 1
    fi
    FAKE_GITHUB_PORT=$FAKE_GITHUB_PORT FAKE_GITHUB_TOKEN=$FAKE_GITHUB_TOKEN FAKE_GITHUB_BIND=$FAKE_GITHUB_BIND \
        bun tests/fake-github/server.js &
    FAKE_PID=$!
    echo "$FAKE_PID" > "$FAKE_PIDFILE"
fi
# The trap is installed only now: a run refused above touched nothing and
# must leave authapp as it found it.
trap cleanup EXIT INT TERM
wait_for "the fake GitHub on $FAKE_GITHUB_URL (pid $FAKE_PID)" fake_is_up

compose build authapp
authapp_with_fake
# authapp is ready when Caddy proxies its login route; the redirect to CAS
# is the sign.
wait_for "authapp behind https://localhost" authapp_answers_login

FAKE_GITHUB_URL=$FAKE_GITHUB_URL GITHUB_PROVISIONER_TOKEN=$FAKE_GITHUB_TOKEN \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
    bun test --max-concurrency=1 --timeout 60000 --preload ./tests/bun-rest-setup.js ./tests/provisioning/lifecycle.js

bun run test_authapp_static
