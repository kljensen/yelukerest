#! /bin/sh

# exit if a command fails
set -e

apk update

# install pg_dump
apk add postgresql

# install s3 tools
apk add python3 py3-pip
pip install awscli

# install supercronic
apk add curl

# Detect architecture and set appropriate supercronic binary
ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
  SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-arm64
  SUPERCRONIC_SHA1SUM=e0f0c06ebc5627e43b25475711e694450489ab00
  SUPERCRONIC_BIN=supercronic-linux-arm64
else
  SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64
  SUPERCRONIC_SHA1SUM=71b0d58cc53f6bd72cf2f293e09e294b79c666d8
  SUPERCRONIC_BIN=supercronic-linux-amd64
fi

curl -fsSLO "$SUPERCRONIC_URL" \
  && echo "${SUPERCRONIC_SHA1SUM}  ${SUPERCRONIC_BIN}" | sha1sum -c - \
  && chmod +x ${SUPERCRONIC_BIN} \
  && mv ${SUPERCRONIC_BIN} /usr/local/bin/supercronic
apk del curl

# cleanup
rm -rf /var/cache/apk/*

