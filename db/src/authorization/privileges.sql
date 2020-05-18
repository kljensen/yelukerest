\echo # Loading roles privilege

-- this file contains the privileges of all aplications roles to each database entity
-- if it gets too long, you can split it one file per entity

-- Uncomment line below to grant RPC privileges for all the entities created by the auth lib
-- and also give anonymous users certain privileges.
-- select auth.set_auth_endpoints_privileges('api', :'anonymous', enum_range(null::data.user_role)::text[]);
-- grant execute on function pgjwt.sign to api;
-- grant usage on schema pgjwt to api, student, ta, faculty;
grant execute on function auth.sign_jwt to api, student, ta, faculty;

-- specify which application roles can access this api (you'll probably list them all)
-- remember to list all the values of user_role type here
grant usage on schema api to anonymous, student, ta, faculty, authapp;


\ir ./yeluke.sql
