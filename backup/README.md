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

## The codeframe artifact backup

pgBackRest covers PostgreSQL and nothing else. The `codeframe_db` volume holds
the pages students publish for the tacky-website activity, plus the
`publish-log.jsonl` that names who published each one. Those pages are the
graded submission -- the activity asks for a URL, not a repository -- so
`codeframe.sh` tars that volume and puts it in S3 (issue #369).

It runs from `backup.sh`, after the PostgreSQL backup and its `info` report, and
inside a guard. Ordering it last means a slow or failing artifact upload cannot
delay or prevent the backup that has a deadline; guarding it means a failed
upload to an unrelated prefix says nothing about the repository. The run still
exits non-zero so the failure is not silent, and the message names which of the
two failed.

Details worth knowing before changing it:

- The archives go to `${S3_PREFIX}-codeframe`, a **sibling** of the pgBackRest
  prefix, never inside it. Nothing in that namespace belongs to a stanza.
- Objects are named `codeframe-<UTC timestamp>-<content hash>.tar.gz`. The hash
  is over a sorted list of per-file digests, not over the tarball, because gzip
  stamps the time into its header and BusyBox `tar` cannot sort. If the newest
  object in the prefix already carries the current hash, nothing is uploaded --
  on an hourly schedule that turns `CODEFRAME_RETAIN` from a count of runs into
  a count of distinct volume states.
- Every upload is read back and compared by digest before the prune runs, and
  the prune runs only after that succeeds, so a truncated upload can never be
  the reason an older good archive was deleted.
- `mcli` is Alpine's `minio-client` package: one static binary from the
  distribution's own repository, and it points at any S3 endpoint. It reads the
  same `S3_ENDPOINT` / `PGBACKREST_REPO1_STORAGE_PORT` /
  `PGBACKREST_REPO1_STORAGE_VERIFY_TLS` settings pgBackRest does, so there is
  one answer to where this stack writes to S3.

Restoring is in `docs/backup-recovery.md`.
