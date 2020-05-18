\echo # Loading auth schema

-- functions for JWT token generation in the database context
\ir ../pgjwt/pgjwt.sql


drop schema if exists auth cascade;
create schema auth;
set search_path = auth, public;


create or replace function sign_jwt(user_id int, "role" data.user_role) returns text as $$
    select pgjwt.sign(
      json_build_object(
        'user_id', user_id,
        'role', "role"::TEXT,
        'exp', extract(epoch from now())::integer + settings.get('jwt_lifetime')::int -- token expires in 1 hour
      ),
      settings.get('jwt_secret'))
$$ stable security definer language sql;
revoke all privileges on function sign_jwt(int, data.user_role) from public;
