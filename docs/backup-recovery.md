# Recovering Data From Backups

Owner: Kyle Jensen. If you are reading this because something is lost, you are
the operator now; work through it in order and do not skip the verification
step.

Production Postgres is backed up by pgBackRest to S3: one base backup plus
continuous WAL archiving, which together allow point-in-time recovery (PITR) —
restoring a copy of the whole cluster as it existed at a chosen instant.

Two different things are backed up, to two different places in the same bucket,
and they have nothing to do with each other:

| What | How | Where in the bucket | Restoring it |
| --- | --- | --- | --- |
| The Postgres cluster | pgBackRest, base backups plus WAL | `$BACKUP_S3_PREFIX/` | most of this document |
| The published student pages on the `codeframe_db` volume | a gzipped tar per changed state | `$BACKUP_S3_PREFIX-codeframe/` | *The codeframe artifacts* below |

Everything from here to *Making the narrow repair against production* is about
the database. Skip to the codeframe section if that is what you lost.

The local harness `bin/test-pgbackrest.sh` (`bun run test_pgbackrest`) proves
the mechanism end to end against a disposable Postgres volume and a self-hosted
MinIO endpoint. It backs up, restores, then restores again to a time before a
marker row and checks the marker is absent. Read it before you read the
procedure below — the steps here are the same shape, pointed at the real S3
repository, and this document does not repeat what that script already encodes.
It also drives `backup.sh`'s backup-type decision through repository states that
cannot be staged in a two-minute run — a week-old full, an `info` that fails, an
`info` whose output does not parse — using the stub pgBackRest in
`bin/pgbackrest-test-stub/`, and asserts that the failing cases take no backup.

## What this protects against, and what it does not

It protects against **logical loss inside the database**: a clobbered
submission body, a mistaken `DELETE`, a migration that dropped the wrong
column, a bad bulk update from `pythonclient`. Anything whose correct value
existed in the cluster at some earlier instant is recoverable.

It does not protect against:

- **Loss outside Postgres.** The `.env` file, secrets, Caddy certificates, and
  the Docker images themselves are not in any backup. The one non-Postgres
  thing that *is* covered is the `codeframe_db` volume, separately and by a
  different mechanism; see *The codeframe artifacts* below.
- **Host loss, in any tested sense.** Rebuilding the server from nothing has
  never been rehearsed. The backups would very likely support it, but that is a
  belief, not a result.
- **Disclosure.** The repository cipher is `none`. Backups sit in S3 in the
  clear, protected only by the bucket's access controls. Anyone holding
  `BACKUP_S3_ACCESS_KEY_ID` can read every student's work. Treat those
  credentials the way you treat `SUPER_USER_PASSWORD`.
- **Silent corruption you notice late.** Recovery requires knowing roughly
  *when* the damage happened. See *Finding the target time* below.

## The recovery window

The window is bounded by the **oldest full backup still in the repository**,
not by a rolling number of days, and it moves in jumps rather than sliding
smoothly.

**Observed 2026-08-27: back to 2026-08-20 19:51 UTC**, the timestamp of what
was then the only full backup (`20260820-195144F`). At that point the
repository held:

- stanza `yelukerest`, status `ok`, cipher `none`
- one full backup, `20260820-195144F`, plus roughly 162 incrementals; the most
  recent completed 2026-08-27 18:00 UTC (`BACKUP_SCHEDULE` is hourly, which the
  incremental count over seven days matches)
- a continuous WAL chain from `000000010000000000000001` — the first segment
  the cluster ever wrote — through `000000010000000300000036`
- database roughly 42.7 MB; the compressed backup set roughly 5.5 MB
- `pg_stat_archiver` showing `failed_count = 0` and no `last_failed_wal`

That state was a single point of failure: every one of those incrementals was
a delta against `20260820-195144F`, so losing that one object in S3 would have
made the entire repository unrestorable. `backup.sh` ran `pgbackrest backup`
with no `--type`, and pgBackRest defaults to incremental once any full exists,
so no second full was ever taken. `PGBACKREST_REPO1_RETENTION_FULL` expires
*fulls*, so with one full it had never pruned anything either. Issue #341.

### How the window moves now

Since 2026-08-27, `backup/backup.sh` chooses the type instead of accepting
pgBackRest's default. It reads the newest full backup's date out of
`pgbackrest info` and takes:

- a **full** when that full is at least `BACKUP_FULL_INTERVAL_DAYS` days old
  (default 7, set in `backup/Dockerfile`, overridable in `.env`), or when the
  repository has no full at all;
- an **incremental** otherwise.

The age is elapsed time, not calendar days: the whole `YYYYMMDD-HHMMSS`
timestamp in the backup label is compared against the clock, so a full taken at
23:59 UTC is seven days old at 23:59 seven days later, not just after midnight
six days later.

So fulls arrive weekly and the hourly runs in between stay incremental. The
rule is stated as an age rather than a weekday deliberately: a fresh stanza and
a week whose full failed both look overdue, so the next run repairs the gap
instead of waiting for the next calendar slot.

**If the repository cannot be read, the run takes no backup at all.** A failed
`pgbackrest info`, or output the script cannot parse, aborts before `backup`
runs. That is deliberate and it is the safe direction. The tempting alternative
-- assume the worst and take a full -- is the one that loses data: retention 2
expires the oldest full and the WAL it anchors the moment a third full lands, so
a single transient S3 or credential failure would collapse the window to the age
of the newest full, and a persistent parse failure on an hourly schedule would
pin it at an hour indefinitely while every run still exited zero. An aborted run
changes nothing in the repository and the next attempt is an hour later. Repeated
aborts show up as a non-zero exit in `docker compose logs backup`; treat them as
an outage of backups, not of recoverability.

**What `PGBACKREST_REPO1_RETENTION_FULL=2` means in practice.** Keep the two
most recent full backups *and everything that depends on them* — their
incrementals, and the WAL archive from the oldest kept full onward. Anything
older is deleted from S3. pgBackRest expires as part of a successful `backup`,
so pruning happens the instant a new full completes, not on a separate
schedule. Raising the number costs storage roughly linearly (a full of this
database is a few MB, but the retained WAL between fulls is the larger share);
lowering it to 1 would recreate the single-point-of-failure this section
describes.

With a weekly full and retention 2, the practical consequences are:

1. **The reachable window is between one and two weeks**, never a fixed
   fourteen days. It is longest just before a new full lands and shortest just
   after: when the third full completes, the first full and the WAL it anchored
   are expired in the same operation, and the window jumps forward by a week.
2. **It moves without anyone doing anything.** A target that was reachable
   yesterday can be gone today. Before you plan a restore against an old
   target, re-read the actual window from `pgbackrest info` (step 1 below);
   never plan against the date written in this document.
3. **A lost or corrupt full no longer takes everything with it.** The most
   recent week's incrementals depend on the newest full, but the older full and
   its own chain are independent — losing one costs part of the window, not all
   of it.
4. **Recovering something older than the window is not possible from here.**
   There is no other copy. If the course needs a longer window, raise
   `PGBACKREST_REPO1_RETENTION_FULL`; deciding that after the fact is not an
   option.

`bin/doctor.sh` checks this: on the production host it runs `backup.sh info`
and warns if the repository holds fewer than two full backups.

## The realistic recovery story

**This is not a one-button undo, and it is not a production rollback.** If you
imagine one, you will make bad decisions under pressure.

What you actually do to recover a single clobbered submission body:

1. Restore the **entire cluster** into an **isolated scratch container** at a
   point in time before the loss.
2. `SELECT` the value you need out of that scratch cluster.
3. Apply a **narrow, hand-written repair** to live production — one `UPDATE`,
   one row.
4. Throw the scratch cluster away.

Production is never stopped, never rewound, and never touched by pgBackRest.
Rolling production back to 01:00 to recover one row would discard every
legitimate write since 01:00, which for a course of students mid-assignment is
far worse than the original loss. The restore is a **reading device**, not a
repair.

This shape means the repair is only as good as your knowledge of what to
repair. Get the row identity and the target time right before you start
restoring.

## Finding the target time

`data.assignment_field_submission_event` is append-only and records every write
to a submission field: `created_at`, `body_sha256`, `body_length`,
`submission_updated_at`, and who did it. It does **not** store the body — that
is exactly why a restore is needed — but it tells you when the damage landed
and gives you a hash to check your recovered text against.

```sql
-- Against live production, via ./bin/pg_connect.sh
SELECT id, created_at, event_type, body_length, body_sha256,
       submitter_user_id, created_by_user_id
  FROM data.assignment_field_submission_event
 WHERE assignment_submission_id = :submission_id
   AND assignment_field_slug = :field_slug
 ORDER BY created_at;
```

Your target is any instant **strictly between the last good event and the event
that destroyed it**. If they are seconds apart, a second after the good event
is fine. Write down that good event's `body_sha256`; you will check the
recovered text against it before writing anything back.

## Running a restore

Everything below runs on the production host, in the repository directory, and
touches only a scratch Docker volume.

> **The one thing that must be true.** The `-v` flag must name your drill
> volume. If it ever names `$PG_DATA_VOLUME_NAME` — the live data volume — you
> are no longer running a drill. The live volume is never mounted by any
> command in this section. That isolation, not care, is what makes this safe to
> run against production.

Load the credentials without printing them:

```sh
set -a; . ./.env; set +a
DRILL_VOLUME=yelukerest-restore-drill
docker volume create "$DRILL_VOLUME"
```

### Step 1: write the pgBackRest config and confirm the repository

The config goes on the volume at `/var/lib/postgresql/pgbackrest-restore.conf`,
**outside** `PGDATA` (`/var/lib/postgresql/18/docker`), for two reasons: the
restore in step 2 wipes `PGDATA`, and the recovered cluster needs the config at
*startup* because its `restore_command` shells out to `pgbackrest archive-get`.

```sh
docker run --rm \
  -e S3_REGION="$BACKUP_S3_REGION" \
  -e S3_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY_ID" \
  -e S3_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_ACCESS_KEY" \
  -e S3_BUCKET="$BACKUP_S3_BUCKET" \
  -e S3_PREFIX="$BACKUP_S3_PREFIX" \
  -e POSTGRES_DATA_PATH=/var/lib/postgresql/18/docker \
  -v "$DRILL_VOLUME:/var/lib/postgresql" \
  --entrypoint sh \
  yelukerest-postgres:18.4-pgbackrest -ceu '
    repo_path="/${S3_PREFIX}"
    # pgBackRest reads PGBACKREST_* environment variables as configuration and
    # they beat the config file. The backup image sets
    # PGBACKREST_REPO1_PATH=/pgbackrest; the db image does not. Rather than
    # depend on knowing which image you are in, set it explicitly to agree with
    # the file. Getting this wrong makes `info` report "missing stanza path"
    # against a repository that is perfectly healthy -- and it once broke the
    # backup path in production for real (commit afe9121).
    export PGBACKREST_REPO1_PATH="$repo_path"

    cat > /var/lib/postgresql/pgbackrest-restore.conf <<EOF
[global]
repo1-type=s3
repo1-path=${repo_path}
repo1-s3-bucket=${S3_BUCKET}
repo1-s3-key=${S3_ACCESS_KEY_ID}
repo1-s3-key-secret=${S3_SECRET_ACCESS_KEY}
repo1-s3-region=${S3_REGION}
log-level-console=info

[yelukerest]
pg1-path=${POSTGRES_DATA_PATH}
EOF

    pgbackrest --config=/var/lib/postgresql/pgbackrest-restore.conf \
      --stanza=yelukerest info
  '
```

You want `status: ok`, and a backup list whose oldest entry brackets your
target time. If `info` reports a missing stanza path, re-read the comment above
about `PGBACKREST_REPO1_PATH` before you conclude the backups are gone.

### Step 2: restore to the target time

```sh
RESTORE_TARGET_TIME='2026-08-22 01:00:00+00'   # your target, with a UTC offset

docker run --rm \
  -e S3_REGION="$BACKUP_S3_REGION" \
  -e S3_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY_ID" \
  -e S3_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_ACCESS_KEY" \
  -e S3_BUCKET="$BACKUP_S3_BUCKET" \
  -e S3_PREFIX="$BACKUP_S3_PREFIX" \
  -e POSTGRES_DATA_PATH=/var/lib/postgresql/18/docker \
  -e RESTORE_TARGET_TIME="$RESTORE_TARGET_TIME" \
  -v "$DRILL_VOLUME:/var/lib/postgresql" \
  --entrypoint sh \
  yelukerest-postgres:18.4-pgbackrest -ceu '
    export PGBACKREST_REPO1_PATH="/${S3_PREFIX}"
    rm -rf "$POSTGRES_DATA_PATH"
    mkdir -p "$POSTGRES_DATA_PATH"

    pgbackrest --config=/var/lib/postgresql/pgbackrest-restore.conf \
      --stanza=yelukerest \
      --type=time \
      --target="$RESTORE_TARGET_TIME" \
      --target-action=pause \
      restore

    chown -R postgres:postgres /var/lib/postgresql
  '
```

Two choices in there are load-bearing:

- **`--target-action=pause`, not `promote`.** Paused, the recovered cluster
  stays in recovery and answers read-only queries — which is all you need.
  Promoting it ends recovery and starts a **new timeline**, which is a durable
  fact written into the repository's history and can confuse a later restore.
  The local harness uses `promote` because its MinIO repository is thrown away
  at the end of the run; a drill against the production repository must not.
- **The image must be `yelukerest-postgres:18.4-pgbackrest`.** Stock
  `postgres:18.4` cannot finish recovery: the generated `restore_command`
  invokes `pgbackrest archive-get`, and stock Postgres has no pgBackRest
  binary. The cluster will start, fail to fetch WAL, and sit there looking
  broken for a reason that has nothing to do with your backups.

There are no external tablespaces — `pg_tablespace` holds only `pg_default` and
`pg_global` — so no `--tablespace-map` is needed. If the schema ever gains one,
restores will need explicit mappings and this paragraph is wrong.

### Step 3: start the recovered cluster, read-only and inert

```sh
docker run -d --name yelukerest-restore-drill-db \
  -e POSTGRES_USER="$SUPER_USER" \
  -e POSTGRES_PASSWORD="$SUPER_USER_PASSWORD" \
  -e POSTGRES_DB="$DB_NAME" \
  -v "$DRILL_VOLUME:/var/lib/postgresql" \
  yelukerest-postgres:18.4-pgbackrest \
  postgres -c archive_mode=off
```

`archive_mode=off` is not cosmetic. The recovered cluster carries production's
own credentials and archive command, so with archiving on it could push WAL
into the **shared** S3 repository that your real backups live in. Turning it
off makes that impossible rather than merely unlikely. No port is published;
query it with `docker exec`, never over the network.

Confirm `postgresql.auto.conf` points its `restore_command` at the config file
that is still on the volume:

```sh
docker exec yelukerest-restore-drill-db \
  grep restore_command /var/lib/postgresql/18/docker/postgresql.auto.conf
```

## Verifying the restore landed where you asked

A restore that starts is not a restore that is correct. Check three things.

**1. It is still in recovery** — i.e. `pause` held and no timeline was created:

```sh
docker exec yelukerest-restore-drill-db \
  psql -U "$SUPER_USER" -d "$DB_NAME" -tAc 'SELECT pg_is_in_recovery();'
```

Expect `t`. An `f` here means the cluster promoted; discard it and redo step 2.

**2. Something you know postdates the target is absent.** Pick a fact whose
timestamp you can check in live production and that falls *after* your target.

**3. Something independent agrees.** One absent row can be explained away; two
unrelated facts agreeing on the same boundary cannot.

### The 2026-08-27 drill, as the worked example

Run against the **production** repository, at target `2026-08-22 01:00:00+00` —
roughly 13 minutes before the term's 26 course meetings were inserted, whose
earliest `created_at` in live production is `2026-08-22T01:13:09Z`:

| Check | Result | What it proves |
| --- | --- | --- |
| `pg_is_in_recovery()` | `true` | paused, not promoted; no new timeline |
| `count(data.meeting)` | `0` | recovery stopped before the 01:13 insert |
| `count(data."user")` | `1` | the TA, added 2026-08-27, is absent |

The meeting count establishes the boundary; the user count confirms it from an
unrelated table a week apart, which is what rules out "the restore is just
empty." Production was not modified at any point and the drill left nothing
behind.

The drill did **not** rehearse recovering a submission body specifically, and
it did not exercise the oldest reachable point. See *What has not been tested*.

### Clean up

```sh
docker rm -f yelukerest-restore-drill-db
docker volume rm "$DRILL_VOLUME"
```

Do this even if the drill failed. A stale scratch volume holding a full copy of
student data is a disclosure problem sitting on the host.

## Making the narrow repair against production

You have the original text from the scratch cluster. Check it before you write
it: hash it and compare against the `body_sha256` of the last good event.

```sql
-- In the scratch cluster
SELECT encode(public.digest(body, 'sha256'), 'hex'), octet_length(body), body
  FROM data.assignment_field_submission
 WHERE assignment_submission_id = :submission_id
   AND assignment_field_slug = :field_slug;
```

If that hash does not equal the last good event's `body_sha256`, you restored
to the wrong instant. Go back to step 2 with a different target rather than
writing a value you have not confirmed.

Then, against live production:

```sql
UPDATE data.assignment_field_submission
   SET body = $restored$...the recovered text...$restored$
 WHERE assignment_submission_id = :submission_id
   AND assignment_field_slug = :field_slug;
```

Notes that will save you a confusing ten minutes:

- **Do not set `updated_at` yourself.** The `BEFORE` trigger treats a
  `NEW.updated_at` that differs from `OLD.updated_at` as a stale
  optimistic-concurrency write and raises `stale write rejected`. Leave the
  column alone; the trigger stamps `current_timestamp` for you.
- **Authorship is preserved.** `request.user_id()` is `NULL` in a direct psql
  session, so the trigger keeps the existing `submitter_user_id`. The repair
  does not reassign the work to you.
- **The repair is itself audited.** The `AFTER` trigger appends a `revised`
  event whose `body_sha256` should equal the last good event's hash, and whose
  `created_by_user_id` is `NULL` — that null is the fingerprint of a direct
  database repair rather than an API write. Confirm both after the `UPDATE`.
- **Dollar-quote the body.** Student text contains quotes and backslashes.

## The codeframe artifacts (published student pages)

This is a separate backup of a separate thing, and it is not point-in-time.

The `codeframe_db` volume holds every page a student has published for the
tacky-website activity, as `cf_<hash>.frame`, plus `publish-log.jsonl` naming
who published each one. Those pages are the graded submission: the activity asks
for a URL, so `https://code.656.mba/f/<html>/<js>.html` *is* the work, and
2025's submissions are recorded that way. Nothing else holds a copy. Issue #369.

`backup/codeframe.sh` runs inside the backup container after each PostgreSQL
backup and writes a gzipped tar of that volume to
`s3://$BACKUP_S3_BUCKET/$BACKUP_S3_PREFIX-codeframe/`, named
`codeframe-<UTC timestamp>-<content hash>.tar.gz`. A run whose content hash
matches the newest object uploads nothing, so on the hourly schedule the
`CODEFRAME_RETAIN` archives kept (default 14) are fourteen *distinct states of
the volume*, not fourteen hours.

**What that buys and what it does not.** You can recover the volume as it was at
any of the retained states. You cannot recover an instant between them, and you
cannot recover a page that was published and lost inside one interval. In
practice frames are content-addressed and append-only — publishing never
overwrites an existing frame — so the realistic loss is the whole volume, and
for that this is enough.

### Restoring the frames

The frames are files, so this is much less delicate than the database
procedure. Run it on the production host, in the repository directory. The
backup container already knows the bucket, prefix, and endpoint, so use it
rather than retyping them — `codeframe.sh` carries `list` and `get` for exactly
this, and a hand-written second copy of those settings is what once produced an
unrestorable pgBackRest repository.

```sh
set -a; . ./.env; set +a          # for $NAKED_FQDN in the verification below
compose() {
  docker compose -f docker-compose.base.yaml -f docker-compose.prod.yaml "$@"
}
mkdir -p tmp/codeframe-restore
```

List what is in S3 and pick one. Object names sort chronologically:

```sh
compose exec backup sh /codeframe.sh list
```

Download it to the host:

```sh
ARCHIVE=codeframe-20260830-144119-cbff9feb7216.tar.gz   # one from the list above

compose run --rm --no-deps -v "$PWD/tmp/codeframe-restore:/out" \
  --entrypoint sh backup /codeframe.sh get "$ARCHIVE" /out
```
Look inside before writing anything into the live volume:

```sh
tar -tzf "tmp/codeframe-restore/$ARCHIVE" | head
```

**Now decide which of the two restores you are doing, before extracting
anything.** They differ only in how they treat `publish-log.jsonl`, and the
wrong one destroys attribution that is not in the archive:

```sh
CODEFRAME_VOLUME=$(compose ps -q codeframe \
  | xargs docker inspect -f '{{range .Mounts}}{{if eq .Destination "/codeframe/db"}}{{.Name}}{{end}}{{end}}')
echo "$CODEFRAME_VOLUME"   # sanity-check the name before anything writes to it

compose stop codeframe     # the only writer; stop it before reading or writing

docker run --rm -v "$CODEFRAME_VOLUME:/codeframe/db:ro" alpine:3.24.1 \
  sh -ceu 'if [ -s /codeframe/db/publish-log.jsonl ]; then
             echo "LIVE LOG PRESENT: use the merging restore"
           else
             echo "no live log: the direct restore is safe"
           fi'
```

codeframe stays stopped for the whole of either procedure below. Read the
volume through a throwaway container rather than `compose exec`, which cannot
reach a stopped service anyway.

#### If there is no live log — empty or newly created volume

`tar -xzf` merges: it writes what is in the archive and leaves everything else
alone. Frames are content-addressed, so one restored from an old archive and one
published since cannot collide.

```sh
docker run --rm \
  -v "$CODEFRAME_VOLUME:/codeframe/db" \
  -v "$PWD/tmp/codeframe-restore:/in:ro" \
  alpine:3.24.1 tar -xzf "/in/$ARCHIVE" -C /codeframe/db

compose start codeframe
```

#### If a live log is present — the usual case

Merging is required, because `publish-log.jsonl` is a single appended-to file
rather than content-addressed: extracting the archive over a newer log truncates
it to the archive's contents and loses the attribution for every publish since.

The live log is read here with codeframe already stopped, deliberately. Reading
it while the service is running loses any publish that lands between the read
and the replacement — the frame survives, its attribution does not.

```sh
mkdir -p tmp/codeframe-scratch
docker run --rm -v "$PWD/tmp/codeframe-restore:/in:ro" \
  -v "$PWD/tmp/codeframe-scratch:/out" \
  alpine:3.24.1 tar -xzf "/in/$ARCHIVE" -C /out

# codeframe is already stopped, so nothing can append while this runs
docker run --rm -v "$CODEFRAME_VOLUME:/codeframe/db:ro" alpine:3.24.1 \
  cat /codeframe/db/publish-log.jsonl > tmp/publish-log.live.jsonl

sort -u tmp/codeframe-scratch/publish-log.jsonl tmp/publish-log.live.jsonl \
  > tmp/publish-log.merged.jsonl
rm tmp/codeframe-scratch/publish-log.jsonl

docker run --rm -v "$CODEFRAME_VOLUME:/codeframe/db" \
  -v "$PWD/tmp/codeframe-scratch:/in:ro" \
  -v "$PWD/tmp/publish-log.merged.jsonl:/log:ro" \
  alpine:3.24.1 sh -ceu '
    cp -a /in/. /codeframe/db/
    cp /log /codeframe/db/publish-log.jsonl
  '

compose start codeframe
```

Check the merge before starting codeframe if the log matters to you: the merged
file should have at least as many lines as the live one did.

`sort -u` is right here only because the log is one JSON object per line and
duplicate lines are duplicates; it reorders the file, which nothing reads
positionally. Delete `tmp/codeframe-restore`, `tmp/codeframe-scratch`, and the
two `publish-log.*.jsonl` files when you are done — they hold student work.

### Verifying it

Fetch one restored page over HTTP, at the URL a submission actually recorded:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' \
  "https://code.${NAKED_FQDN}/f/<html-hash>/<js-hash>.html"
```

A `200` from the public artifact host is the check that matters, because that is
the form the grade referenced. A file on the volume that Caddy will not serve is
not a restored submission.

## What to check periodically

`pgbackrest info` looking healthy is **not** evidence that a restore works. It
reports what the repository claims about itself. The failure mode that actually
happened here — base backups and their WAL written to two different S3
prefixes, commit afe9121 — produced a repository that looked fine and could not
be restored from at all. Only a restore is evidence of a restore.

Each term, and after any change to the backup path, the db image, the S3
configuration, or the Postgres major version:

- Run `bun run test_pgbackrest`. It proves the code path, including PITR, in a
  few minutes against a disposable repository.
- Run one real drill against the production repository, steps 1–3 above, at a
  target a day or two old. Record the target and the verification results in
  this document's worked-example section.
- Query `pg_stat_archiver` on production for `failed_count`,
  `last_failed_wal`, and `last_archived_time`. A rising `failed_count` means
  WAL is not reaching S3 and the recovery window has silently stopped
  advancing.
- Re-read the recovery window from `pgbackrest info` and update the date above
  if a new full backup has expired the old one.
- Run `./bin/doctor.sh` on the production host, which warns when the
  repository holds fewer than two full backups. Fewer than two a week after
  deployment means the weekly full is not happening; read the backup
  container's log (`docker compose logs backup`) for the line naming the
  backup type it chose.
- List `$BACKUP_S3_PREFIX-codeframe/` and check the newest archive is not older
  than the last time anyone published a page. Because unchanged volumes are not
  re-uploaded, an old newest archive is normal on a quiet week and only
  suspicious after a class that published. A failing artifact backup also makes
  the whole backup run exit non-zero with a line saying so, so
  `docker compose logs backup` is the faster check.

## RPO and RTO, as observed

**RPO — how much you can lose.** `archive_timeout` is `60s`
(`docker-compose.prod.yaml`), so Postgres forces a WAL segment out at least
once a minute. The theoretical exposure is therefore about a minute of writes:
whatever sits in the current, un-archived segment when the database is lost.
This is only relevant to losing the *database*; for the logical-loss cases this
runbook is actually about, every write is already archived and the RPO is
effectively zero.

**RTO — how long recovery takes.** The 2026-08-27 drill restored a ~43 MB
cluster in well under a minute, and the cluster was answering queries seconds
later. Do not read that as your incident RTO. In a real incident the clock is
dominated by:

- working out *what* was lost and *when* — the slowest step, and the one
  nothing automates;
- reading the event history to pick a target time and a hash to check against;
- writing and double-checking the narrow repair by hand.

Budget an hour of human attention for a single-row recovery by someone
following this document, and treat the restore itself as free. If many rows are
affected, the repair scales linearly and the restore still does not.

## What has not been tested

Stated plainly so nobody quotes this document for more than it supports:

- **The oldest recovery point has never been restored.** Only a recent target
  (2026-08-22) was exercised. Whether the repository can actually reach back to
  2026-08-20 19:51 UTC is inferred from `pgbackrest info`, not demonstrated.
- **Only one backup chain was exercised.** The incrementals needed for that
  single target were read successfully. The other ~160 have never been used.
- **Host-loss recovery has never been rehearsed.** Restoring the cluster onto a
  fresh machine and bringing the full stack up on it is untested.
- **No restore from a full other than `20260820-195144F` has been done.** The
  weekly fulls are taken but restoring from a later one is unrehearsed, and it
  is the case most likely to be needed once the first full expires.
- **The submission-recovery path end to end** — clobber a body, restore,
  extract, repair — has been rehearsed only in the local harness's sentinel-row
  form, not against production data.
- **The codeframe restore has never been run against the production bucket.**
  It was proved locally against MinIO on 2026-08-30 — back up a volume holding
  known frames and a publish log, upload, download, extract into an empty
  volume, and compare every file by digest, which matched — but the production
  archives have never been downloaded, and no restored page has been fetched
  through Caddy to confirm the URL still resolves.
- **The `publish-log.jsonl` merge has not been rehearsed at all.** It is written
  down above because extracting an old archive straight over a live log would
  destroy attribution, not because anyone has done it.

See issue #338 for the drill that produced this document.
