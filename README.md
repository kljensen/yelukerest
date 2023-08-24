# Yelukerest: software for managing my classes at Yale

This repo contains software for managing my classes at Yale. The major
functions of the software include:

- recording student enrollment and participation;
- storing class information, such as meeting times, meeting subjects, and pre-class reading;
- storing and administering multiple choice quizzes;
- storing assignment information and accepting assignment submissions; and,
- storing student grades on assignments and quizzes.

The core of the application is a RESTful API built on top of
[postgrest](https://postgrest.readthedocs.io). In addition, the application
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
docker-compose -f ./docker-compose.base.yaml -f ./docker-compose.dev.yaml up
# For production
docker-compose -f ./docker-compose.base.yaml -f ./docker-compose.prod.yaml up
```

The roles of the most important components are as follows:

- _[postgres](https://www.postgresql.org/)_ - provides persistence nearly all
  of the application data and enforces
  relational integrity.
- _backup_ - Saves backups of the production postgres database to S3, usually hourly.
- _[rabbitmq](https://www.rabbitmq.com/)_ - subscription/notification
  service generally used to alert applications
  to changes in the database, such as new rows.
- _[pg_amqp_bridge](https://github.com/subzerocloud/pg-amqp-bridge)_ -
  sends NOTIFY events from postgres to rabbitmq.
- _postgrest_ - provides a RESTful API over the postgres application database.
- _[openresty](https://openresty.org)_ - the webserver that accepts incoming
  HTTP requests and proxies them to relevant backend services, such as postgrest.
- _[certbot](https://certbot.eff.org/)_ - obtains and renews SSL certificates
  for openresty.
- _elmclient_ - a front-end client that runs in web browsers and communicates
  with the API. This is the main way in which students interact with the
  API.
- _sse_ - a backend service that accepts
  [sse](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events) connections so that the elmclient
  can subscribe to table changes in postgres (via rabbitmq and pg_amqp_bridge).

It will likely be necessary to read the documentation of
[Postgrest](https://postgrest.com/en/v4.3/) and the
[Postgrest starter kit](https://github.com/subzerocloud/postgrest-starter-kit/wiki)
to understand how all this fits together.

## Testing

To run the tests, do `npm test` from the root of this project.
The containers will need to be running. This will run [pgTAP](http://pgtap.org/)
tests and tests of the REST API using [supertest](https://github.com/visionmedia/supertest). See the `test` directory.

## Starting in a new development environment

When you checkout this repo anew and wish to work on yelukerest you'll
need to complete a few steps.

1. Create the letsencrypt volume
   `docker volume create --name=yelukerest-letsencrypt`
2. Create local certs for https
   `./bin/create-local-dev-https-certs.sh`
3. Create the `.env` file with all the variables you need. Likely best to get this from another
   machine on which the code is working.
4. Start the server
   `./bin/dev.sh up`

## Starting in a new production environment

When I begin a new school year, I'll likely want to
run the `create-initial-migrations.sh` script to get fresh migrations.
I'll likely want to throw out the old ones first. I only keep migrations
for a semester then start over. Then...

0. Create your secrets. Notices that the jwt secret [must be longer than 32 chars](https://github.com/PostgREST/postgrest/issues/991).
1. Create the required external docker volumes 
   ```
   docker volume create --name=yelukerest-pg-data
   docker volume create --name=yelukerest-redis-data
   docker volume create --name=yelukerest-letsencrypt
   ```
2. Start database `./bin/prod.sh up db`
3. Run the migrations (make sure these are up-to-date ;P )
   `./bin/migrate.sh`
4. Stop database
5. Get letsencrypt certs (see below)
6. Get AWS S3 bucket permissions all set up for backups.
7. Insert the klj39 user
   ```
   insert into data.user(email, netid, name, lastname, nickname, role)
   values ('kyle.jensen@yale.edu', 'klj39', 'Kyle Jensen', 'Jensen', 'bald-chicken', 'faculty');
   ```
7. Update the JWTs in your .env
8. Restart. Good to go.

If you get a CAS error it is because you didn't set up the JWTs. You will need at least the following.

For `AUTHAPP_JWT`
```
./bin/jwt.sh {"role": "app", "app_name": "authapp"}'
```

For `YELUKEREST_CLIENT_JWT` (user klj39's user id)
```
./bin/jwt.sh '{"user_id": "1", "role": "faculty"}
```

For `SWAGGER_JWT`
```
./bin/jwt.sh '{"role": "student"}'
```

## Random notes

### Restoring production backups

Backups are saved to s3 hourly in production. To restore, download one,
then run something like

```
pg_restore --host $HOST -U superuser -d app --port $PORT --clean --exit-on-error ./thebackup.dump
```

The `--clean` will drop (or truncate?) tables.

### Getting the initial letsencrypt certificate in production

To get certificates _issued_ do something like the following

```
bin/create-initial-certbot-https-cert.sh
```

Run that when not running anything else. Data are persisted to the yelukerest-letsencrypt data volume.
You must have the `FDQN` environment variable set to your fully qualified domain name and obviously
your DNS records should be set such that that domain name resolves to the IP address of the machine
on which you run the command. The command will spin up a temporary http server and therefore your
firewall in need to be open on ports 80 and 443 for inbound connections.

### Adding a table when working on the database

1. Add the table in `db/src/data/yeluke.sql`
2. Add the table in `db/src/sample_data/yeluke/reset.sql`
3. Add the api views in `db/src/api/yeluke.sql`
4. Add the auth in `db/src/authorization/yeluke.sql`
5. Add sample data in `db/src/sample_data/yeluke/data.sql`
6. Add the tests in `tests/db/`

### Thoughts on the auth flow

1. Most requests will go through OpenResty to the PostgREST instance
   and require JWT tokens---very few of the API endpoints have information
   for anonymous users. The JWT was signed using our private key,
   so we know we created it and we're going to trust it. For most of
   those, the JWT specifies a database "role" we wish to assume and
   also the "user_id" of the person. For more, read
   [here](https://github.com/subzerocloud/postgrest-starter-kit/wiki/Athentication-Authorization-Flow).
2. Our database will generate the JWT tokens for us, as described above.
   Or, we could use node to do this for us. See
   [node-jsonwebtoken](https://github.com/auth0/node-jsonwebtoken).
3. We use the node app to verify that the person logging-in is a Yale
   affiliate. We need to verify that the person who authenticates with
   CAS is also in our database. (We get their netid directly from Yale's
   CAS server via https, so it is sufficient to check for the existance
   of this user.) Once we do that, we should get them some JWT tokens
   whenever their client---likely an ELM app in the browser---needs to
   interact with the API. We should give those JWT tokens short expiration
   times and refresh them as needed.


## Random notes

### Restoring production backups

Backups are saved to s3 hourly in production. To restore, download one,
then run something like

```
pg_restore --host $HOST -U superuser -d app --port $PORT --clean --exit-on-error ./thebackup.dump
```

The `--clean` will drop (or truncate?) tables.

### Adding a table when working on the database

1. Add the table in `db/src/data/yeluke.sql`
2. Add the table in `db/src/sample_data/yeluke/reset.sql`
3. Add the api views in `db/src/api/yeluke.sql`
4. Add the auth in `db/src/authorization/yeluke.sql`
5. Add sample data in `db/src/sample_data/yeluke/data.sql`
6. Add the tests in `tests/db/`

### Thoughts on the auth flow

1. Most requests will go through OpenResty to the PostgREST instance
   and require JWT tokens---very few of the API endpoints have information
   for anonymous users. The JWT was signed using our private key,
   so we know we created it and we're going to trust it. For most of
   those, the JWT specifies a database "role" we wish to assume and
   also the "user_id" of the person. For more, read
   [here](https://github.com/subzerocloud/postgrest-starter-kit/wiki/Athentication-Authorization-Flow).
2. Our database will generate the JWT tokens for us, as described above.
   Or, we could use node to do this for us. See
   [node-jsonwebtoken](https://github.com/auth0/node-jsonwebtoken).
3. We use the node app to verify that the person logging-in is a Yale
   affiliate. We need to verify that the person who authenticates with
   CAS is also in our database. (We get their netid directly from Yale's
   CAS server via https, so it is sufficient to check for the existance
   of this user.) Once we do that, we should get them some JWT tokens
   whenever their client---likely an ELM app in the browser---needs to
   interact with the API. We should give those JWT tokens short expiration
   times and refresh them as needed.
