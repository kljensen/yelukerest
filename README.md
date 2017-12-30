# A restful API for class data
We are using the excellent [postgrest start kit](https://github.com/subzerocloud/postgrest-starter-kit). The main
entrypoint to this code is `docker-compose.yaml`, which shows what
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

### Adding a table when working on the database

1. Add the table in  `db/src/data/yeluke`
2. Add the auth in `db/src/authorization/yeluke`
3. Add the api views in `db/src/api/yeluke`
4. Add sample data in `db/src/sample_data/yeluke`
5. Add the tests in `tests/db/`