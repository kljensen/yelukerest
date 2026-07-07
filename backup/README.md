# pgBackRest backup

This image runs pgBackRest against the Postgres data directory and stores
backups in an S3-compatible repository.

The backup container expects PostgreSQL WAL archiving to be enabled with the
repository settings used by pgBackRest. It runs `stanza-create`, `check`, and
`backup`, so a failed archive-push path fails the backup instead of silently
producing a full backup without point-in-time recovery coverage.
