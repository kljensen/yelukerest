\echo # Loading auth schema

-- functions for JWT token generation in the database context
\ir ../pgjwt/pgjwt.sql


drop schema if exists auth cascade;
create schema auth;
set search_path = auth, public;


create or replace function sign_jwt(user_id int, "role" data.user_role) returns text
volatile
security definer
language sql
set search_path = pg_catalog, auth, settings, pgjwt, pg_temp
return pgjwt.sign(
      json_build_object(
        'iss', settings.get('jwt_issuer'),
        'aud', settings.get('jwt_audience'),
        'sub', 'user:' || user_id::text,
        'user_id', user_id,
        'role', "role"::TEXT,
        'iat', extract(epoch from now())::integer,
        'nbf', extract(epoch from now())::integer,
        'jti', public.gen_random_uuid()::text,
        'exp', extract(epoch from now())::integer + settings.get('jwt_lifetime')::int -- token expires in 1 hour
      ),
      settings.get('jwt_secret'));
revoke all privileges on function sign_jwt(int, data.user_role) from public;
