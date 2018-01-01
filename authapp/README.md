# Authapp

This small node application is responsible for a few
things:

* Handling CAS auth flow
* Checking that CAS authenticated users are also our users (they exist in the database)
* Signing JWT tokens so that API clients can speak to the REST API.