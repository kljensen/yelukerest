begin;
select plan(25);

create or replace function verify_jwt(jwt text) RETURNS TABLE(header json, payload json, valid boolean)
stable
security definer
language sql
set search_path = pg_catalog, pgjwt, settings, pg_temp
begin atomic
    select *
    from pgjwt.verify(jwt, settings.get('jwt_secret'));
end;

SELECT view_owner_is(
    'api', 'user_jwts', 'api',
    'api.user_jwts view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'user_jwts', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.user_jwts"'
);

SELECT table_privs_are(
    'api', 'user_jwts', 'ta', ARRAY['SELECT'],
    'ta should only be granted SELECT on view "api.user_jwts"'
);

SELECT table_privs_are(
    'api', 'user_jwts', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted select on view "api.user_jwts"'
);

SELECT table_privs_are(
    'api', 'user_jwts', 'app', ARRAY[]::TEXT[],
    'app should not be granted direct SELECT on view "api.user_jwts"'
);

SELECT function_privs_are(
    'api', 'issue_user_jwt', ARRAY['text'], 'app', ARRAY['EXECUTE'],
    'app should only be granted EXECUTE on function "api.issue_user_jwt"'
);

set local role anonymous;
set request.jwt.claim.role = 'anonymous';
SELECT throws_like(
    'select (id) from api.user_jwts',
    '%permission denied%',
    'anonymous users should not be able to use the api.user_jwts view'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
SELECT set_eq(
    'SELECT (id) FROM api.user_jwts ORDER BY id',
    ARRAY[1,2,3,4,5],
    'faculty should be able to select from the api.user_jwts view'
);

set local role ta;
set request.jwt.claim.role = 'ta';
set request.jwt.claim.user_id = '4';

SELECT set_eq(
    'SELECT (id) FROM api.user_jwts ORDER BY id',
    ARRAY[1,2,3,4,5],
    'ta should be able to select ids from the api.user_jwts view'
);

SELECT set_eq(
    'SELECT (jwt) FROM api.user_jwts WHERE id != 4',
    ARRAY[null, null, null, null],
    'ta should be able to select ids from the api.user_jwts view but they should be null'
);

SELECT set_eq(
    'SELECT (jwt) FROM api.user_jwts WHERE id != 4',
    ARRAY[null, null, null, null],
    'ta should be able to select ids from the api.user_jwts view but they should be null'
);

SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'user_id' "user_id" FROM api.user_jwts where id=4;
    $$,
    ARRAY['4'],
    'ta should be able to select their own jwt'
);

SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'user_id' "user_id" FROM api.user_jwts;
    $$,
    ARRAY['4', null],
    'ta should be able to select their own jwt and not that of others'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'user_id' "user_id" FROM api.user_jwts;
    $$,
    ARRAY['1'],
    'students should be able to select their own jwt and not that of others'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';
SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'user_id' "user_id" FROM api.user_jwts;
    $$,
    ARRAY['1', '2', '3', '4', null],
    'faculty should be able to select non-observer user jwts'
);

set local role faculty;
set request.jwt.claim.role = '';
set request.jwt.claim.user_id = '';
SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'user_id' "user_id" FROM api.user_jwts;
    $$,
    (ARRAY[])::TEXT[],
    'users with no role should not be able to select any user jwts'
);

set local role app;
set request.jwt.claim.role = 'app';
set request.jwt.claim.user_id = '';
set request.jwt.claim.app_name = 'authapp';
SELECT throws_like(
    $$
        SELECT (jwt) FROM api.user_jwts WHERE id = 5;
    $$,
    '%permission denied%',
    'the authapp should not directly select from api.user_jwts'
);

SELECT set_eq(
    $$
        SELECT (jwt) FROM api.issue_user_jwt('crt43');
    $$,
    ARRAY[null],
    'the authapp should not mint observer user jwts through the issue_user_jwt RPC'
);

SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'user_id' "user_id" FROM api.issue_user_jwt('abc123');
    $$,
    ARRAY['1'],
    'the authapp should be able to mint one user jwt through the issue_user_jwt RPC'
);

set request.jwt.claim.app_name = 'fooapp';
SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'user_id' "user_id" FROM api.issue_user_jwt('abc123');
    $$,
    (ARRAY[])::TEXT[],
    'other apps should not be able to mint user jwts through the issue_user_jwt RPC'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'iss' FROM api.user_jwts WHERE id = 1;
    $$,
    ARRAY['yelukerest'],
    'user jwts should include an issuer'
);

SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'aud' FROM api.user_jwts WHERE id = 1;
    $$,
    ARRAY['yelukerest-postgrest'],
    'user jwts should include the PostgREST audience'
);

SELECT set_eq(
    $$
        SELECT (verify_jwt(jwt)).payload::json->>'sub' FROM api.user_jwts WHERE id = 1;
    $$,
    ARRAY['user:1'],
    'user jwts should include a stable subject'
);

SELECT isnt_empty(
    $$
        SELECT 1
        FROM api.user_jwts
        CROSS JOIN LATERAL verify_jwt(jwt) verified
        WHERE id = 1
        AND (verified.payload::json->>'iat')::integer <= extract(epoch from now())::integer
        AND (verified.payload::json->>'nbf')::integer <= extract(epoch from now())::integer
        AND (verified.payload::json->>'exp')::integer > extract(epoch from now())::integer
    $$,
    'user jwts should include valid issued-at, not-before, and expiry claims'
);

SELECT isnt_empty(
    $$
        SELECT 1
        FROM api.user_jwts
        CROSS JOIN LATERAL verify_jwt(jwt) verified
        WHERE id = 1
        AND (verified.payload::json->>'jti') ~ '^[0-9a-f-]{36}$'
    $$,
    'user jwts should include a token id'
);


select * from finish();
rollback;
