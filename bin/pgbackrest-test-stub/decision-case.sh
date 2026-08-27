#!/bin/sh
# Runs backup.sh inside the backup image with the stub pgbackrest ahead of the
# real one, then prints a single machine-readable line the host compares against
# the expected outcome. Exits 0 whatever backup.sh does: the exit status under
# test is reported in that line, not propagated.

set -u

export PATH="/stub:$PATH"
: > /tmp/stub-calls

rc=0
sh /backup.sh > /tmp/stub-output 2>&1 || rc=$?

printf 'rc=%s calls=%s\n' "$rc" "$(tr '\n' ',' < /tmp/stub-calls)"
cat /tmp/stub-output >&2
