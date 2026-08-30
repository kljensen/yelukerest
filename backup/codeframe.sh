#!/bin/sh

# Copies the codeframe volume to S3 as a gzipped tar.
#
# That volume holds every page a student has published for the tacky-website
# activity, plus the publish log naming who published each one. The activity
# asks for a URL rather than a repository, so the file on that volume *is* the
# graded submission and no other copy of it exists anywhere (issue #369).
#
# backup.sh runs this after the PostgreSQL backup, and treats a failure here as
# non-fatal to that backup. It also carries the two read-only commands a restore
# needs, so that recovering does not mean hand-writing the endpoint settings a
# second time. That is the same reason `backup.sh info` exists: pgBackRest's
# repo settings were once written out by hand in a third place, and the copies
# drifted into a repository that could not be restored from (commit afe9121).
#
#   docker compose exec backup sh /codeframe.sh          # back up now
#   docker compose exec backup sh /codeframe.sh list     # what is in S3
#   docker compose exec backup sh /codeframe.sh get NAME DIR

set -e

if [ -z "${S3_ACCESS_KEY_ID:-}" ] || [ "${S3_ACCESS_KEY_ID}" = "**None**" ]; then
  echo "You need to set the S3_ACCESS_KEY_ID environment variable."
  exit 1
fi

if [ -z "${S3_SECRET_ACCESS_KEY:-}" ] || [ "${S3_SECRET_ACCESS_KEY}" = "**None**" ]; then
  echo "You need to set the S3_SECRET_ACCESS_KEY environment variable."
  exit 1
fi

if [ -z "${S3_BUCKET:-}" ] || [ "${S3_BUCKET}" = "**None**" ]; then
  echo "You need to set the S3_BUCKET environment variable."
  exit 1
fi

# A sibling of the pgBackRest prefix, never a child of it. pgBackRest treats
# everything under repo1-path as its repository, and these tarballs belong to no
# stanza; keeping them outside that namespace means neither `pgbackrest expire`
# nor a human reading the repository can mistake one for backup state.
CODEFRAME_S3_PREFIX=${CODEFRAME_S3_PREFIX:-${S3_PREFIX}-codeframe}

# How many archives to keep. Only *distinct* volume contents are uploaded (see
# the fingerprint below), so on the hourly production schedule this is a count
# of changes rather than of runs, and it exists so that one truncated or
# corrupted upload cannot be the only copy.
CODEFRAME_RETAIN=${CODEFRAME_RETAIN:-14}

# Mirror pgBackRest's endpoint settings rather than inventing a second set, so
# there is one answer to "where does this stack write to S3". An unset endpoint
# means real AWS, which is what production uses; a bare hostname is what
# repo1-s3-endpoint takes, and it pairs with the storage port and TLS-verify
# settings the db and backup services already share.
if [ -z "${S3_ENDPOINT:-}" ] || [ "${S3_ENDPOINT}" = "**None**" ]; then
  S3_URL="https://s3.${S3_REGION}.amazonaws.com"
else
  case "$S3_ENDPOINT" in
    http://* | https://*) S3_URL="$S3_ENDPOINT" ;;
    *) S3_URL="https://${S3_ENDPOINT}:${PGBACKREST_REPO1_STORAGE_PORT:-443}" ;;
  esac
fi

if [ "${PGBACKREST_REPO1_STORAGE_VERIFY_TLS:-y}" = "n" ]; then
  export MC_INSECURE=true
fi

WORK_DIR=$(mktemp -d)
# mcli writes the credentials into its config directory. Point that at a
# throwaway directory so the secret lives no longer than the run does.
MC_CONFIG_DIR="$WORK_DIR/mcli"
export MC_CONFIG_DIR
trap 'rm -rf "$WORK_DIR"' EXIT

ALIAS=codeframe-backup
TARGET="${ALIAS}/${S3_BUCKET}/${CODEFRAME_S3_PREFIX}"

mcli --quiet --no-color alias set \
  "$ALIAS" "$S3_URL" "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY" >/dev/null

case "${1:-backup}" in
  list)
    mcli --quiet --no-color ls "${TARGET}/"
    exit 0
    ;;
  get)
    # Downloads one archive to a directory the caller has mounted into this
    # container. Extracting is deliberately not done here: this container mounts
    # the codeframe volume read-only, and restoring wants codeframe stopped and
    # the publish log merged rather than overwritten. See docs/backup-recovery.md.
    if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
      echo "usage: sh /codeframe.sh get <archive-name> <destination-directory>" >&2
      exit 1
    fi
    mcli --quiet --no-color cp "${TARGET}/${2}" "${3}/"
    exit 0
    ;;
  backup) ;;
  *)
    echo "usage: sh /codeframe.sh [backup|list|get <archive-name> <destination-directory>]" >&2
    exit 1
    ;;
esac

# The compose file mounts the volume read-only at this path. A missing directory
# means the mount is absent, not that there is nothing to back up, so fail rather
# than quietly upload an empty archive that would then look like the current
# state of the volume.
if [ ! -d "$CODEFRAME_DATA_PATH" ]; then
  echo "Codeframe data path does not exist: $CODEFRAME_DATA_PATH" >&2
  echo "The backup service must mount the codeframe_db volume there." >&2
  exit 1
fi

# Fingerprint the file contents, not the tarball. gzip stamps the current time
# into its header and busybox tar has no --sort, so archiving an unchanged
# directory twice produces different bytes; a sorted list of per-file digests
# does not. This is what makes "nothing changed, skip the upload" safe, which on
# an hourly schedule is the difference between a retention window measured in
# days and one measured in publishes.
CONTENT_HASH=$(
  cd "$CODEFRAME_DATA_PATH" &&
    find . -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum | cut -c1-12
)

OBJECT="codeframe-$(date -u +%Y%m%d-%H%M%S)-${CONTENT_HASH}.tar.gz"

# Listing is a separate command whose status is checked, not a stage in a
# pipeline: `set -e` reports only the last command in a pipeline, so a failed
# list piped into awk would look exactly like "this prefix holds nothing" -- and
# believing that would skip the dedup check and run the prune below against a
# truncated view of what exists. mcli distinguishes the two for us: a prefix with
# no objects lists empty and exits zero, and only a real failure (bad
# credentials, missing bucket, unreachable endpoint) exits non-zero.
if ! LISTING=$(mcli --quiet --no-color ls "${TARGET}/" 2>&1); then
  printf '%s\n' "$LISTING" >&2
  echo "Could not list ${S3_BUCKET}/${CODEFRAME_S3_PREFIX}; aborting rather than acting on an unknown set of archives" >&2
  exit 1
fi

# `ls` prints "[date] size class name"; take the name and keep only our own
# objects, so anything else that lands in the prefix is never a prune candidate.
EXISTING=$(printf '%s\n' "$LISTING" | awk '{ print $NF }' | grep '^codeframe-.*\.tar\.gz$' | LC_ALL=C sort || true)

# Object names begin with a UTC timestamp, so lexical order is chronological.
NEWEST=$(printf '%s\n' "$EXISTING" | tail -n 1)

case "$NEWEST" in
  *-"${CONTENT_HASH}".tar.gz)
    echo "Codeframe volume unchanged since ${NEWEST}; nothing to upload"
    exit 0
    ;;
esac

TARBALL="$WORK_DIR/$OBJECT"
tar -czf "$TARBALL" -C "$CODEFRAME_DATA_PATH" .

mcli --quiet --no-color cp "$TARBALL" "${TARGET}/${OBJECT}" >/dev/null

# Read the object back and compare digests. mcli reports a failed upload, but it
# cannot report an object that arrived truncated or was written over, and this
# archive is only worth keeping if it can be read. The round trip is affordable
# because the data is tens of small files; if it ever stops being that, compare
# `mcli stat` sizes instead of re-downloading.
LOCAL_SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)
REMOTE_SHA=$(mcli --quiet --no-color cat "${TARGET}/${OBJECT}" | sha256sum | cut -d' ' -f1)

if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  echo "Uploaded ${OBJECT} does not read back with the digest it was written with; leaving it in place for inspection" >&2
  exit 1
fi

echo "Uploaded ${OBJECT} ($(wc -c < "$TARBALL") bytes) to ${S3_BUCKET}/${CODEFRAME_S3_PREFIX}"

# Prune only after the new archive has been written and verified, so a failed
# upload can never shrink the set of archives that already exist. The archive
# just uploaded counts toward the retained set, hence the +1.
EXISTING_COUNT=$(printf '%s' "$EXISTING" | grep -c . || true)
PRUNE_COUNT=$(( EXISTING_COUNT + 1 - CODEFRAME_RETAIN ))

if [ "$PRUNE_COUNT" -gt 0 ]; then
  for old in $(printf '%s\n' "$EXISTING" | grep . | head -n "$PRUNE_COUNT"); do
    mcli --quiet --no-color rm "${TARGET}/${old}" >/dev/null
    echo "Removed ${old} (keeping the newest ${CODEFRAME_RETAIN})"
  done
fi
