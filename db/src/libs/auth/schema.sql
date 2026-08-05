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

-- Sign a short-lived internal user JWT for the MCP token exchange
-- (issue #263, ADR 0001). Differences from sign_jwt:
--   * 10-minute TTL (not the browser flow's 1 hour) to shrink the
--     blast radius of the public mcpapp endpoint;
--   * a `scopes` claim: a space-separated scope list (the OAuth
--     "scope" parameter convention, RFC 6749 section 3.3) so PostgREST
--     surfaces it via request.jwt.claims and the database can read it
--     back with request.jwt_claim('scopes');
--   * a `netid` claim so downstream consumers need not re-resolve it;
--   * the caller supplies the jti so the token id can be recorded in
--     the data.mcp_jwt_mint_event audit table in the same transaction.
-- The audience is the PostgREST audience: these tokens go to PostgREST
-- only. The MCP-audience bearer tokens (aud=yelukerest-mcp) are a
-- different product (issue #264) and are never signed by this function.
create or replace function sign_mcp_user_jwt(user_id int, "role" data.user_role, netid text, scopes text, jti text) returns text
volatile
security definer
language sql
set search_path = pg_catalog, auth, settings, pgjwt, pg_temp
return pgjwt.sign(
      json_build_object(
        'iss', settings.get('jwt_issuer'),
        -- Array audience: this one token is presented to BOTH mcpapp
        -- (which requires the MCP audience) and, forwarded by mcpapp,
        -- to PostgREST (which requires its own). api.check_request_jwt
        -- and mcpapp both accept an audience array by membership.
        'aud', json_build_array(
            settings.get('jwt_audience'),
            coalesce(settings.get('jwt_mcp_audience'), 'yelukerest-mcp')),
        'sub', 'user:' || user_id::text,
        'user_id', user_id,
        'role', "role"::TEXT,
        'netid', netid,
        'scopes', scopes,
        'iat', extract(epoch from now())::integer,
        'nbf', extract(epoch from now())::integer,
        'jti', jti,
        'exp', extract(epoch from now())::integer + 600 -- token expires in 10 minutes
      ),
      settings.get('jwt_secret'));
revoke all privileges on function sign_mcp_user_jwt(int, data.user_role, text, text, text) from public;
