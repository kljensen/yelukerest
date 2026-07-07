#!/bin/sh

set -e

if [ "${SCHEDULE}" = "**None**" ]; then
  sh backup.sh
else
  echo "$SCHEDULE /bin/sh /backup.sh" > /etc/crontabs/root
  exec crond -f -l 8
fi
