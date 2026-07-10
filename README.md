# Yelukerest: software for managing my classes at Yale

This repo contains software for managing my classes at Yale. The major
functions of the software include:

- recording student enrollment and participation;
- storing class information, such as meeting times, meeting subjects, and pre-class reading;
- storing paper quiz metadata and grades;
- storing assignment information and accepting assignment submissions; and,
- storing student grades on assignments and quizzes.

The core of the application is an HTTP API exposed by
[PostgREST](https://postgrest.org/en/stable/). In addition, the application
includes a web front-end for interacting with the API. For me, Yelukerest
replaces Canvas and allows me to do many things that I cannot do easily with
Canvas, particularly manipulating class information in an automatic fashion,
e.g. updating student grades. When I use Yelukerest, I have one instance
running per course and I usually also have a separate "admin" repo in which I
store things that are course specific, such as homework assignments and
automated grading code. Yelukerest (this code) contains nothing that is course
specific.  The database schema in Yelukerest is generic such that I can use it
for multiple courses.  The schema attempts to make impossible states impossible
to represent and it also makes liberal use of Postgres' row-level permissions
in order to manage access to data such that, e.g. students cannot alter their
grades, can only see their own grades, etc. Such behavior is ensured through
extensive declarative tests at the database level. Indeed, almost all the 
important behavior of Yelukerest is in the database (Postgres) layer.

The structure of this repo is
taken from the excellent
[postgrest start kit](https://github.com/subzerocloud/postgrest-starter-kit).
The application includes a number of components each of which runs in a
[docker](https://en.wikipedia.org/wiki/Docker_%28software%29) container.
The main
entrypoint is `docker-compose*.yml`, which shows what
containers are started in dev and production.

```
# For development
docker compose -f ./docker-compose.base.yaml -f ./docker-compose.dev.yaml up
# For production
docker compose -f ./docker-compose.base.yaml -f ./docker-compose.prod.yaml up
```

The roles of the most important components are as follows:

- _[postgres](https://www.postgresql.org/)_ - provides persistence nearly all
  of the application data and enforces
  relational integrity.
- _backup_ - Saves pgBackRest backups of the production postgres database to
  S3, usually hourly.
- _postgrest_ - provides an HTTP API over the postgres application database.
- _elmclient_ - a front-end client that runs in web browsers and communicates
  with the API. This is the main way in which students interact with the
  API. The Elm compiler version is pinned in `elmclient/elm.json`; build tools
  are copied from the pinned `ghcr.io/kljensen/docker-elm-dev-static:0.19.2`
  image in `elmclient/Dockerfile`.

It will likely be necessary to read the documentation of
[PostgREST](https://postgrest.org/en/stable/) and the
[Postgrest starter kit](https://github.com/subzerocloud/postgrest-starter-kit/wiki)
to understand how all this fits together.

## Testing

To smoke-test a running local or production-like stack through Caddy, run:

```
./bin/smoke.sh
# or
bun run smoke
```

The smoke test is a fast wiring check for Compose services, HTTPS proxying,
PostgREST, authapp login routing, the static OpenAPI UI, and database reachability. It does
not replace the database, REST, or Elm test suites. See
`docs/smoke-test.md` for the exact checks and production overrides.

To run the database and REST tests, do `bun run test` from the root of this
project. The containers will need to be running. This will run
[pgTAP](http://pgtap.org/) tests through local `pg_prove` and tests of the REST
API using [supertest](https://github.com/ladjs/supertest). See the `tests`
directory.

To run the Elm client tests:

```
docker compose -f docker-compose.base.yaml -f docker-compose.dev.yaml build elmclient
docker compose -f docker-compose.base.yaml -f docker-compose.dev.yaml run --rm elmclient-test
```

To inspect the current local container image sizes:

```
bun run image_sizes
```

See `docs/image-budget.md` for the current Alpine/static image posture and the
known external image exceptions.

## Starting in a new development environment

When you checkout this repo anew and wish to work on yelukerest you'll
need to complete a few steps.

3. Create the `.env` file with all the variables you need. Likely best to get this from another
   machine on which the code is working.
4. Start the server
   `./bin/dev.sh up`

## Starting in a new production environment

When I begin a new school year, I'll likely want to
run the `create-initial-migrations.sh` script to get fresh migrations.
I'll likely want to throw out the old ones first. I only keep migrations
for a semester then start over. These Sqitch migrations are a verified
bootstrap for a new course database, not a reversible production history:
`./bin/migrate.sh` deploys with verification, and rollback is restore from
backup or rebuild/drop the disposable database rather than `sqitch revert`.
PostgreSQL major upgrades are the same kind of operation: dump/restore,
`pg_upgrade`, or create a fresh course database, but do not expect an old data
volume to start in place under a new major version. PostgreSQL 18 Docker images
also store data under `/var/lib/postgresql/18/docker` by default, so the
production volume mounts `/var/lib/postgresql`, not the old
`/var/lib/postgresql/data` path.
Then...

0. If you're using tailscale, make sure you do not use tailscale
   DNS or it will screw with the container DNS systems (docker 
   will copy the tailscale resolv.conf into the containers!).
   Start tailscale with
   `doas tailscale up --accept-dns=false`

0. Create your secrets. Notices that the jwt secret [must be longer than 32 chars](https://github.com/PostgREST/postgrest/issues/991).
1. Create the required external docker volumes 
   ```
   docker volume create --name=yelukerest-pg-data
   docker volume create --name=yelukerest-letsencrypt
   ```
2. Start database `./bin/prod.sh up db`
3. Run the migrations (make sure these are up-to-date ;P )
   `./bin/migrate.sh`
4. Stop database
6. Get AWS S3 bucket permissions all set up for backups.
7. Insert the klj39 user
   ```
   insert into data.user(email, netid, name, lastname, nickname, role)
   values ('kyle.jensen@yale.edu', 'klj39', 'Kyle Jensen', 'Jensen', 'bald-chicken', 'faculty');
   ```
7. Update the JWTs in your .env
8. Restart. Good to go.

If you get a CAS error it may be because `AUTHAPP_JWT` is missing or invalid.
See `docs/auth-jwt-flow.md` for the full CAS/session/PostgREST JWT model.
Course admin tooling should check the deployed platform/schema compatibility
version before making admin changes. See `docs/platform-compatibility.md`.

For `AUTHAPP_JWT`
```
./bin/jwt.sh '{"role":"app","app_name":"authapp"}'
```

For `YELUKEREST_CLIENT_JWT` (user klj39's user id)
```
./bin/jwt.sh '{"user_id":1,"role":"faculty"}'
```

`bin/jwt.sh` adds the standard issuer, audience, subject, issued-at,
not-before, and token-id claims used by the stricter JWT validator. After
regenerating hand-minted service/client tokens, set:

```
PRE_REQUEST=api.check_request_jwt
```

This enables the PostgREST pre-request hook that rejects authenticated JWTs
with the wrong issuer, missing/wrong audience, or missing subject.

## Random notes

### Restoring production backups

Backups are saved to S3 through pgBackRest. The local backup harness exercises
the same backup image against a disposable Postgres volume and a self-hosted
MinIO S3 endpoint:

```
bun run test_pgbackrest
```

Use `pgbackrest restore` with the production stanza and repository settings to
restore a physical backup. WAL archiving is enabled in the production Compose
Postgres service so backups can support point-in-time recovery when the S3
repository retains the needed WAL range.

### Adding a table when working on the database

1. Add the table in `db/src/data/yeluke.sql`
2. Add the table in `db/src/sample_data/yeluke/reset.sql`
3. Add the api views in `db/src/api/yeluke.sql`
4. Add the auth in `db/src/authorization/yeluke.sql`
5. Add sample data in `db/src/sample_data/yeluke/data.sql`
6. Add the tests in `tests/db/`
