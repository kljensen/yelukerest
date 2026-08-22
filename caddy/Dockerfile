ARG CADDY_IMAGE=ghcr.io/kljensen/docker-caddy-dns-static:2.11.4@sha256:5581821ac430d45b356ef2e2a3081a918f83541b57580b033c41c7d8df6d40db

FROM ${CADDY_IMAGE}

# Point Caddy's storage at the mounted volumes.
#
# The official caddy images set these; this one does not, and without them
# Caddy falls back to $HOME/.local/share/caddy. HOME is unset here, so that
# resolves to /.local/share/caddy -- inside the container's writable layer,
# which is discarded on every recreate. The caddy_data volume was mounted at
# /data the whole time and never written to.
#
# The cost of that was invisible until a container was replaced: Caddy came
# back with no certificate and no ACME account, and reissued from Let's
# Encrypt. Let's Encrypt allows five duplicate certificates per week, so a
# handful of ordinary redeploys in one week would have left the site unable to
# obtain a certificate at all, with no way to hurry the window along.
ENV XDG_DATA_HOME=/data
ENV XDG_CONFIG_HOME=/config
