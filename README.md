# A restful API for class data
We are using the excellent [postgrest start kit](https://github.com/subzerocloud/postgrest-starter-kit). The main
entrypoint to this code is `docker-compose.yml`, which shows what
containers are started when you do `docker-compose up`. Once your
containers are running, if you are in the root of this directory,
running `subzero dashboard` will give you a useful view of the 
logs of all the containers and can also restart containers on file
changes.

If you are working on the front-end, most of your work will be
in the `node` directory.

## Getting started in development

1. Install Docker
2. Run `npm install`
3. Install [subzero-cli](https://github.com/subzerocloud/subzero-cli)
4. Run `docker-compose up -d`
5. Run `subzero dashboard` when the containers are up
6. Edit the code you want --- most components of the stack will restart
   on changes.

## Understanding how all this works

It will likely be necessary to read the documentation of 
[Postgrest](https://postgrest.com/en/v4.3/) and the 
[Postgrest starter kit](https://github.com/subzerocloud/postgrest-starter-kit/wiki)
to understand how all this fits together. 

Here are a few pieces that are specific to our setup, particularly
the auth flow.

1. Facutly (TAs) will create users "by hand" in the database
   based on who comes to class. We won't create user accounts
   just based on CAS login as we did in the past.
1. The node application will handle CAS authentication and will
   need to check if users exist in the database when doing so.
1. Once a user is authenticated, the app will ust JWT to communicate
   with the REST API (at `/rest`) to do all the stuff students need
   to do---view lectures, submit assignments, take quizzes.
1. Easy peasy.

## Testing

To run the tests, do `npm test` from the root of this project.
The containers will need to be running. This will run [pgTAP](http://pgtap.org/)
tests and tests of the REST API using [supertest](https://github.com/visionmedia/supertest). See the `test` directory.


## Random notes

### Getting the initial letsencrypt certificate

```
docker run -p 80:80 -it -v yelukerest-letsencrypt:/etc/letsencrypt certbot/certbot  certonly
 --standalone --preferred-challenges http -d www.660.mba
```

Run that when not running anything else. Data are persisted to the yelukerest-letsencrypt data volume.


### Adding a table when working on the database

1. Add the table in  `db/src/data/yeluke.sql`
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
