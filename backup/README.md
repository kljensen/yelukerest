# pgBackRest backup

This image runs pgBackRest against the Postgres data directory and stores
backups in an S3-compatible repository.

The current container performs full physical backups with `archive-check=n`.
That is an improvement over ad hoc logical dumps, but point-in-time recovery
requires a follow-up change to enable PostgreSQL WAL archiving with
`archive_command = 'pgbackrest ... archive-push %p'`.
