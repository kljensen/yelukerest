#!/bin/sh

set -e

if [ -z "${S3_ACCESS_KEY_ID:-}" ] || [ "${S3_ACCESS_KEY_ID}" = "**None**" ]; then
  echo "You need to set the S3_ACCESS_KEY_ID environment variable."
  exit 1
fi

if [ -z "${S3_SECRET_ACCESS_KEY:-}" ] || [ "${S3_SECRET_ACCESS_KEY}" = "**None**" ]; then
  echo "You need to set the S3_SECRET_ACCESS_KEY environment variable."
  exit 1
fi

if [ "${S3_BUCKET}" = "**None**" ]; then
  echo "You need to set the S3_BUCKET environment variable."
  exit 1
fi

if [ "${POSTGRES_USER}" = "**None**" ]; then
  echo "You need to set the POSTGRES_USER environment variable."
  exit 1
fi

if [ -z "${POSTGRES_PASSWORD:-}" ] || [ "${POSTGRES_PASSWORD}" = "**None**" ]; then
  echo "You need to set the POSTGRES_PASSWORD environment variable or link to a container named POSTGRES."
  exit 1
fi

if [ ! -d "$POSTGRES_DATA_PATH" ]; then
  echo "Postgres data path does not exist: $POSTGRES_DATA_PATH"
  exit 1
fi

if [ ! -d "$POSTGRES_SOCKET_PATH" ]; then
  echo "Postgres socket path does not exist: $POSTGRES_SOCKET_PATH"
  exit 1
fi

export PGPASSWORD="$POSTGRES_PASSWORD"
REPO_PATH=$PGBACKREST_REPO1_PATH

if [ -n "${S3_PREFIX:-}" ]; then
  REPO_PATH="/${S3_PREFIX}"
fi

# pgBackRest reads PGBACKREST_* environment variables as configuration, and they
# take precedence over the config file written below. backup/Dockerfile sets
# PGBACKREST_REPO1_PATH=/pgbackrest, so without this export the env var silently
# overrode repo1-path and base backups went to /pgbackrest while the db
# container's archive_command (which has no such env var) wrote WAL to
# /$S3_PREFIX -- backups and their WAL in two different places, so no restore
# could work. Keep the env and the config file in agreement.
export PGBACKREST_REPO1_PATH="$REPO_PATH"

CONFIG=$(mktemp)
trap 'rm -f "$CONFIG"' EXIT

cat > "$CONFIG" <<EOF
[global]
repo1-type=${PGBACKREST_REPO1_TYPE}
repo1-path=${REPO_PATH}
repo1-retention-full=${PGBACKREST_REPO1_RETENTION_FULL}
repo1-s3-bucket=${S3_BUCKET}
repo1-s3-key=${S3_ACCESS_KEY_ID}
repo1-s3-key-secret=${S3_SECRET_ACCESS_KEY}
repo1-s3-region=${S3_REGION}
repo1-s3-uri-style=${PGBACKREST_REPO1_S3_URI_STYLE}
repo1-storage-port=${PGBACKREST_REPO1_STORAGE_PORT}
repo1-storage-verify-tls=${PGBACKREST_REPO1_STORAGE_VERIFY_TLS}
log-level-console=info
start-fast=y

[${PGBACKREST_STANZA}]
pg1-path=${POSTGRES_DATA_PATH}
pg1-port=${POSTGRES_PORT}
pg1-socket-path=${POSTGRES_SOCKET_PATH}
pg1-user=${POSTGRES_USER}
EOF

if [ "${S3_ENDPOINT}" != "**None**" ] && [ -n "${S3_ENDPOINT}" ]; then
  cat >> "$CONFIG" <<EOF
repo1-s3-endpoint=${S3_ENDPOINT}
EOF
fi

# `sh backup.sh info` reports on the repository without touching it, reusing the
# config written above so the report cannot drift from the settings the backups
# themselves use. bin/doctor.sh calls this; a third hand-written copy of the
# repo1-* settings is exactly how base backups and WAL once ended up in two
# different S3 prefixes (commit afe9121).
if [ "${1:-backup}" = "info" ]; then
  pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" info
  exit 0
fi

pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" stanza-create
pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" check

# pgBackRest defaults to an incremental backup once any full exists, so running
# `backup` with no --type chained every run onto the single full taken when the
# stanza was created (issue #341). Losing that one object would invalidate every
# backup at once, and repo1-retention-full only expires *fulls*, so with one full
# retention had never run either. Take a full when the newest one is at least
# BACKUP_FULL_INTERVAL_DAYS old, and an incremental otherwise.
#
# The decision lives here rather than in a second crontab entry in run.sh
# because SCHEDULE is hourly in production: a day-of-week rule would take 24
# fulls on that day, and a separate weekly cron entry would need its own minute
# to avoid racing the hourly entry for the pgBackRest lock. Asking the
# repository how old the newest full is also makes the rule self-correcting --
# a fresh stanza has no full at all, and a week whose full failed still looks
# overdue, so both take a full on the very next run rather than waiting for the
# next calendar slot.
FULL_INTERVAL_DAYS=${BACKUP_FULL_INTERVAL_DAYS:-7}

# Ask the repository how old the newest full backup is. The `info` call is its
# own command, and its status is checked, because `set -e` reports only the
# *last* command in a pipeline: written as `pgbackrest info | sed | tail` a
# failed `info` is hidden behind a successful `tail`, and the empty result is
# then indistinguishable from "this stanza has no full backup yet".
#
# Guessing on that empty result is not safe in either direction, and guessing
# "full" is the dangerous one. repo1-retention-full=2 expires the oldest full
# and all the WAL it anchors the moment a third full lands, so one transient S3
# or credential failure would take an unnecessary full and collapse the recovery
# window to the age of the newest full -- possibly an hour. A persistent parse
# mismatch is worse: production runs hourly, so it would take a full every hour
# and hold the window at an hour indefinitely while every run still reported
# success. Aborting is the safe direction here. The next attempt is one schedule
# tick away, and a run that takes no backup leaves every existing backup, and
# everything they can restore, exactly as it was.
if ! REPO_INFO=$(pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" info --output=text 2>&1); then
  printf '%s\n' "$REPO_INFO" >&2
  echo "pgbackrest info failed; aborting without taking a backup rather than guessing the backup type" >&2
  exit 1
fi

# `info` prints "stanza: <name>" in column zero. Requiring it proves we are
# reading pgBackRest's report for our own stanza rather than empty output or
# something we do not understand.
if ! printf '%s\n' "$REPO_INFO" | grep -q "^stanza: ${PGBACKREST_STANZA}\$"; then
  printf '%s\n' "$REPO_INFO" >&2
  echo "pgbackrest info succeeded but did not report stanza ${PGBACKREST_STANZA}; aborting rather than guessing the backup type" >&2
  exit 1
fi

# Backup labels are YYYYMMDD-HHMMSSF for a full, and `info` lists them oldest
# first, so the last match is the newest full.
LAST_FULL_LABEL=$(printf '%s\n' "$REPO_INFO" \
  | sed -n 's/^ *full backup: \([0-9]\{8\}-[0-9]\{6\}\)F$/\1/p' \
  | tail -n 1)
FULL_BACKUP_LINES=$(printf '%s\n' "$REPO_INFO" | grep -c '^ *full backup: ' || true)

if [ -n "$LAST_FULL_LABEL" ]; then
  # Compare whole timestamps, not just the YYYYMMDD part: a full taken at 23:59
  # UTC would otherwise become "7 days old" just after midnight six days later.
  # `date -D` is a BusyBox extension for parsing a non-default input format; the
  # image is Alpine (backup/Dockerfile) so that is the date we always get. It
  # sets no TZ, so the label pgBackRest wrote and `date -u` here are both UTC.
  # An unparseable label exits non-zero under `set -e` rather than defaulting.
  LAST_FULL_EPOCH=$(date -u -D '%Y%m%d-%H%M%S' -d "$LAST_FULL_LABEL" +%s)
  FULL_AGE_SECONDS=$(( $(date -u +%s) - LAST_FULL_EPOCH ))

  if [ "$FULL_AGE_SECONDS" -ge $(( FULL_INTERVAL_DAYS * 86400 )) ]; then
    BACKUP_TYPE=full
  else
    BACKUP_TYPE=incr
  fi

  echo "Newest full backup ${LAST_FULL_LABEL}F is $(( FULL_AGE_SECONDS / 3600 ))h old; backup type: $BACKUP_TYPE (BACKUP_FULL_INTERVAL_DAYS=$FULL_INTERVAL_DAYS)"
elif [ "$FULL_BACKUP_LINES" -ne 0 ]; then
  # `info` listed fulls but none matched the label format we parse. That is the
  # persistent-mismatch case: left to itself it would take a full every run
  # forever, so stop and make a human look at the output.
  printf '%s\n' "$REPO_INFO" >&2
  echo "pgbackrest info listed $FULL_BACKUP_LINES full backup line(s) but none matched YYYYMMDD-HHMMSSF; aborting rather than taking a full on every run" >&2
  exit 1
else
  # No full backup at all. stanza-create and check both succeeded above, so the
  # stanza is initialized and its archive path is healthy -- this is genuinely a
  # new repository and it needs its first full.
  BACKUP_TYPE=full
  echo "No full backup in the repository; backup type: full (BACKUP_FULL_INTERVAL_DAYS=$FULL_INTERVAL_DAYS)"
fi

# A successful backup also runs expire, so this is the point at which
# repo1-retention-full starts pruning old fulls and the WAL they anchor.
pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" --type="$BACKUP_TYPE" backup
pgbackrest --config="$CONFIG" --stanza="$PGBACKREST_STANZA" info
