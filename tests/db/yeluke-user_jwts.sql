SELECT plan(26)
; CREATE OR REPLACE FUNCTION zapadka_test.verify_jwt(jwt text) RETURNS TABLE (header pg_catalog.json, payload pg_catalog.json, valid boolean) STABLE SECURITY DEFINER LANGUAGE sql SET search_path TO pg_catalog, pgjwt, settings, pg_temp BEGIN ATOMIC
    SELECT *
    FROM pgjwt.verify(jwt, settings.get('jwt_secret'))
; END
; SELECT view_owner_is('api', 'user_jwts', 'api', 'api.user_jwts view should be owned by the api role')
; SELECT table_privs_are('api', 'user_jwts', 'student', ARRAY['SELECT'], 'student should only be granted SELECT on view "api.user_jwts"')
; SELECT table_privs_are('api', 'user_jwts', 'ta', ARRAY['SELECT'], 'ta should only be granted SELECT on view "api.user_jwts"')
; SELECT table_privs_are('api', 'user_jwts', 'faculty', ARRAY['SELECT'], 'faculty should only be granted select on view "api.user_jwts"')
; SELECT table_privs_are('api', 'user_jwts', 'app', ARRAY[]::text[], 'app should not be granted direct SELECT on view "api.user_jwts"')
; SELECT function_privs_are('api', 'issue_user_jwt', ARRAY['text'], 'app', ARRAY['EXECUTE'], 'app should only be granted EXECUTE on function "api.issue_user_jwt"')
; SET LOCAL role TO anonymous
; SET "request.jwt.claim.role" TO anonymous
; SELECT throws_like('select (id) from api.user_jwts', '%permission denied%', 'anonymous users should not be able to use the api.user_jwts view')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SELECT set_eq('SELECT (id) FROM api.user_jwts ORDER BY id', ARRAY[1, 2, 3, 4, 5], 'faculty should be able to select from the api.user_jwts view')
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT set_eq('SELECT (id) FROM api.user_jwts ORDER BY id', ARRAY[1, 2, 3, 4, 5], 'ta should be able to select ids from the api.user_jwts view')
; SELECT set_eq('SELECT (jwt) FROM api.user_jwts WHERE id != 4', ARRAY[NULL, NULL, NULL, NULL], 'ta should be able to select ids from the api.user_jwts view but they should be null')
; SELECT set_eq('SELECT (jwt) FROM api.user_jwts WHERE id != 4', ARRAY[NULL, NULL, NULL, NULL], 'ta should be able to select ids from the api.user_jwts view but they should be null')
; SELECT set_eq('
        SELECT (zapadka_test.verify_jwt(jwt)).payload::json->>''user_id'' "user_id" FROM api.user_jwts where id=4;
    ', ARRAY['4'], 'ta should be able to select their own jwt')
; SELECT set_eq('
        SELECT (zapadka_test.verify_jwt(jwt)).payload::json->>''user_id'' "user_id" FROM api.user_jwts;
    ', ARRAY['4', NULL], 'ta should be able to select their own jwt and not that of others')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT set_eq('
        SELECT (zapadka_test.verify_jwt(jwt)).payload::json->>''user_id'' "user_id" FROM api.user_jwts;
    ', ARRAY['1'], 'students should be able to select their own jwt and not that of others')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT set_eq('
        SELECT (zapadka_test.verify_jwt(jwt)).payload::json->>''user_id'' "user_id" FROM api.user_jwts;
    ', ARRAY['1', '2', '3', '4', NULL], 'faculty should be able to select non-observer user jwts')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO ''
; SET "request.jwt.claim.user_id" TO ''
; SELECT set_eq('
        SELECT (verify_jwt(jwt)).payload::json->>''user_id'' "user_id" FROM api.user_jwts;
    ', ARRAY[]::text[], 'users with no role should not be able to select any user jwts')
; SET LOCAL role TO app
; SET "request.jwt.claim.role" TO app
; SET "request.jwt.claim.user_id" TO ''
; SET "request.jwt.claim.app_name" TO authapp
; SELECT throws_like('
        SELECT (jwt) FROM api.user_jwts WHERE id = 5;
    ', '%permission denied%', 'the authapp should not directly select from api.user_jwts')
; SELECT set_eq('
        SELECT (jwt) FROM api.issue_user_jwt(''crt43'');
    ', ARRAY[NULL], 'the authapp should not mint observer user jwts through the issue_user_jwt RPC')
; SELECT set_eq('
        SELECT (verify_jwt(jwt)).payload::json->>''user_id'' "user_id" FROM api.issue_user_jwt(''abc123'');
    ', ARRAY['1'], 'the authapp should be able to mint one user jwt through the issue_user_jwt RPC')
; SET "request.jwt.claim.app_name" TO fooapp
; SELECT set_eq('
        SELECT (verify_jwt(jwt)).payload::json->>''user_id'' "user_id" FROM api.issue_user_jwt(''abc123'');
    ', ARRAY[]::text[], 'other apps should not be able to mint user jwts through the issue_user_jwt RPC')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT set_eq('
        SELECT (verify_jwt(jwt)).payload::json->>''iss'' FROM api.user_jwts WHERE id = 1;
    ', ARRAY['yelukerest'], 'user jwts should include an issuer')
; SELECT set_eq('
        SELECT (verify_jwt(jwt)).payload::json->>''aud'' FROM api.user_jwts WHERE id = 1;
    ', ARRAY['yelukerest-postgrest'], 'user jwts should include the PostgREST audience')
; SELECT set_eq('
        SELECT (verify_jwt(jwt)).payload::json->>''sub'' FROM api.user_jwts WHERE id = 1;
    ', ARRAY['user:1'], 'user jwts should include a stable subject')
; SELECT isnt_empty('
        SELECT 1
        FROM api.user_jwts
        CROSS JOIN LATERAL verify_jwt(jwt) verified
        WHERE id = 1
        AND (verified.payload::json->>''iat'')::integer <= extract(epoch from now())::integer
        AND (verified.payload::json->>''nbf'')::integer <= extract(epoch from now())::integer
        AND (verified.payload::json->>''exp'')::integer > extract(epoch from now())::integer
    ', 'user jwts should include valid issued-at, not-before, and expiry claims')
; SELECT isnt_empty('
        SELECT 1
        FROM api.user_jwts
        CROSS JOIN LATERAL verify_jwt(jwt) verified
        WHERE id = 1
        AND (verified.payload::json->>''exp'')::integer - (verified.payload::json->>''iat'')::integer <= 3600
    ', 'user jwts should expire within one hour')
; SELECT isnt_empty('
        SELECT 1
        FROM api.user_jwts
        CROSS JOIN LATERAL verify_jwt(jwt) verified
        WHERE id = 1
        AND (verified.payload::json->>''jti'') ~ ''^[0-9a-f-]{36}$''
    ', 'user jwts should include a token id')
; SELECT *
FROM finish()
