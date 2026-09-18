#!/bin/sh
# Enrol the production Postgres on the tailnet as `mgt656-db`, once.
#
# Runs ON THE PRODUCTION HOST. The db-tailscale sidecar in
# docker-compose.prod.yaml carries no auth key; it reuses the node identity
# this script writes into the external volume `db-tailscale-state`. Run it
# before the first `prod.sh up` of the sidecar, and again only if that volume
# is lost (then also delete the stale `mgt656-db` machine in the admin
# console first, or the new one comes up as `mgt656-db-1`).
#
# The auth key arrives on stdin so it is never on a command line, in a log,
# or in .env. Use the tag:deployer OAuth client secret from
# kljensen/home-provisioning (group_vars/tailscale/vault.yaml,
# tailscale_client_secret), which may enrol any tag that tag:deployer owns:
#
#   uv run ansible-vault view group_vars/tailscale/vault.yaml \
#     | yq -r .tailscale_client_secret \
#     | ssh alpine@www.656.mba 'cd yelukerest && ./bin/bootstrap-db-tailscale.sh'
#
# Afterwards, disable key expiry for the machine in the admin console; a
# tagged node does not get that automatically.

set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

volume=db-tailscale-state
name=db-tailscale-bootstrap
image=$(awk '/^  db-tailscale:/{f=1} f && /image:/{print $2; exit}' docker-compose.prod.yaml)
[ -n "$image" ] || { echo "could not read the db-tailscale image from docker-compose.prod.yaml" >&2; exit 1; }

if docker volume inspect "$volume" >/dev/null 2>&1 \
   && docker run --rm -v "$volume":/s "$image" test -s /s/tailscaled.state 2>/dev/null; then
    echo "Refusing: $volume already holds a node identity." >&2
    echo "Remove the machine in the admin console and 'docker volume rm $volume' to re-enrol." >&2
    exit 1
fi

[ -t 0 ] && { echo "Pipe the auth key on stdin; see the header." >&2; exit 1; }
IFS= read -r authkey
[ -n "$authkey" ] || { echo "empty auth key on stdin" >&2; exit 1; }

docker volume create "$volume" >/dev/null

# --reset so a key that was scoped to a different tag set cannot leave stale
# prefs behind. Kernel mode to match the sidecar; the identity does not
# depend on it, but the first `tailscale up` should exercise the same path.
docker run --rm -d --name "$name" \
    -v "$volume":/var/lib/tailscale \
    -e TS_AUTHKEY="$authkey" \
    -e TS_STATE_DIR=/var/lib/tailscale \
    -e TS_HOSTNAME=mgt656-db \
    -e TS_ACCEPT_DNS=false \
    -e TS_USERSPACE=false \
    -e "TS_EXTRA_ARGS=--advertise-tags=tag:mgt656-db --netfilter-mode=off --reset" \
    --device /dev/net/tun --cap-add NET_ADMIN \
    "$image" >/dev/null
unset authkey

i=0
until docker exec "$name" tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; do
    i=$((i + 1))
    if [ "$i" -ge 30 ]; then
        echo "node did not reach Running within 60s; last log lines:" >&2
        docker logs --tail 20 "$name" >&2
        docker stop "$name" >/dev/null
        exit 1
    fi
    sleep 2
done

docker exec "$name" tailscale status --json \
    | awk -F'"' '/"HostName"/ && !h {print "hostname: " $4; h=1} /"DNSName"/ && !d {print "dns:      " $4; d=1} /"tag:/ {print "tag:      " $2}' \
    | head -4
docker stop "$name" >/dev/null
echo "enrolled; now 'prod.sh up -d db-tailscale', then disable key expiry for mgt656-db in the admin console"
