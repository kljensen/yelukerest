# pgBackRest backup

This image runs pgBackRest against the Postgres data directory and stores
backups in an S3-compatible repository.

The backup container expects PostgreSQL WAL archiving to be enabled with the
repository settings used by pgBackRest. It runs `stanza-create`, `check`, and
`backup`, so a failed archive-push path fails the backup instead of silently
producing a full backup without point-in-time recovery coverage.

`backup.sh` chooses the backup type itself: a full when the newest full in the
repository is at least `BACKUP_FULL_INTERVAL_DAYS` (default 7) days old,
measured as elapsed time from the backup label's `YYYYMMDD-HHMMSS` timestamp,
or when the repository has no full at all; an incremental otherwise. Without
that, pgBackRest's default of `incr` chains every backup onto one full forever
(issue #341).

If `pgbackrest info` fails, or succeeds but reports something the script cannot
read, the run aborts and takes no backup. Guessing "full" there would be the
dangerous guess: `repo1-retention-full=2` expires the oldest full and its WAL as
soon as a third full lands, so a transient S3 failure -- or a persistent parse
mismatch on an hourly schedule -- would shrink the recovery window while every
run still looked successful. An aborted run leaves the existing backups
untouched and the next scheduled attempt is an hour away.

`sh backup.sh info` runs `pgbackrest info` using the same generated config and
takes no backup; `bin/doctor.sh` uses it to check that more than one full backup
exists.
