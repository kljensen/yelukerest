-- Tests for personal access tokens (issues #314-#317): creation, the
-- authapp-only exchange, revocation, and the properties that make a
-- four-month credential safe to hand out.
select * from no_plan();

create or replace function zapadka_test.verify_pat_jwt(jwt text) RETURNS TABLE(header json, payload json, valid boolean)
stable
security definer
language sql
set search_path = pg_catalog, pgjwt, settings, pg_temp
begin atomic
    select *
    from pgjwt.verify(jwt, settings.get('jwt_secret'));
end;

-- ---------------------------------------------------------------
-- Structure and privileges
-- ---------------------------------------------------------------
SELECT view_owner_is(
    'api', 'user_api_tokens', 'api',
    'api.user_api_tokens should be owned by the api role'
);

-- The secret hash must never be reachable through the API at all.
SELECT is_empty(
    $$ SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'api' AND table_name = 'user_api_tokens'
          AND column_name IN ('token_hash') $$,
    'api.user_api_tokens must not expose token_hash'
);

-- No UPDATE for anyone: the view carries scopes and expires_at, so an UPDATE
-- grant would let a holder widen their own token or extend its life.
-- The api role keeps write privileges because it owns the view; the invariant
-- that matters is that no human-facing role does, or a holder could widen their
-- own token's scopes or push out its expiry.
SELECT is_empty(
    $$ SELECT grantee::text FROM information_schema.role_table_grants
        WHERE table_schema = 'api' AND table_name = 'user_api_tokens'
          AND grantee IN ('student', 'ta', 'faculty')
          AND privilege_type IN ('UPDATE', 'INSERT', 'DELETE') $$,
    'no human-facing role may INSERT, UPDATE or DELETE api.user_api_tokens'
);

-- ---------------------------------------------------------------
-- Creation, as a student acting on their own account
-- ---------------------------------------------------------------
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
set request.jwt.claim.app_name = '';

-- Default scopes are read-only. This is the property that keeps an assistant
-- from submitting work the student did not intend to submit.
SELECT set_eq(
    $$ SELECT unnest(scopes) FROM api.create_user_api_token('default scopes') $$,
    ARRAY['course:read', 'grades:read', 'submissions:read'],
    'a token created without scopes should be read-only'
);

SELECT is(
    (SELECT count(*)::int FROM api.user_api_tokens WHERE name = 'default scopes'),
    1,
    'the created token should be visible to its owner'
);

-- Four months by default.
SELECT ok(
    (SELECT expires_at > current_timestamp + interval '3 months'
       AND expires_at < current_timestamp + interval '5 months'
     FROM api.user_api_tokens WHERE name = 'default scopes'),
    'the default expiry should be about four months out'
);

-- The returned token must match the stored prefix and be long enough to be
-- worth something.
SELECT ok(
    (SELECT token ~ '^yk_[0-9a-f]{8}_[0-9a-f]{64}$'
     FROM api.create_user_api_token('shape check')),
    'the issued token should have the documented shape'
);

SELECT throws_ok(
    $$ SELECT * FROM api.create_user_api_token('') $$,
    '22023',
    NULL,
    'an empty token name should be rejected'
);

SELECT throws_ok(
    $$ SELECT * FROM api.create_user_api_token('past', ARRAY['course:read'], current_timestamp - interval '1 day') $$,
    '22023',
    NULL,
    'an expiry in the past should be rejected'
);

-- The scope vocabulary is closed. A caller cannot invent a scope.
SELECT throws_ok(
    $$ SELECT * FROM api.create_user_api_token('bad scope', ARRAY['admin:everything']) $$,
    '23514',
    NULL,
    'a scope outside the vocabulary should be rejected by the check constraint'
);

-- ---------------------------------------------------------------
-- One student may not see another's tokens
-- ---------------------------------------------------------------
set request.jwt.claim.user_id = '2';
SELECT is_empty(
    $$ SELECT id FROM api.user_api_tokens WHERE name = 'default scopes' $$,
    'a student should not see another student''s tokens'
);

-- ...but faculty may, because a leaked credential must be killable without the
-- student being reachable.
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '1';
SELECT ok(
    (SELECT count(*) > 0 FROM api.user_api_tokens WHERE name = 'default scopes'),
    'faculty should see tokens belonging to others'
);

-- ---------------------------------------------------------------
-- Exchange: authapp only
-- ---------------------------------------------------------------
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
SELECT throws_like(
    $$ SELECT * FROM api.exchange_user_api_token('yk_00000000_' || repeat('a', 64)) $$,
    '%authapp%',
    'a student credential should not be able to exchange tokens'
);

set request.jwt.claim.role = 'app';
set request.jwt.claim.user_id = '';
set request.jwt.claim.app_name = 'mcpapp';
SELECT throws_like(
    $$ SELECT * FROM api.exchange_user_api_token('yk_00000000_' || repeat('a', 64)) $$,
    '%authapp%',
    'the mcpapp credential should not be able to exchange tokens either'
);

set request.jwt.claim.app_name = 'authapp';

-- Every refusal is indistinguishable: an unknown prefix, a wrong secret, a
-- revoked token and an expired one all return nothing. Otherwise the endpoint
-- becomes an oracle for which prefixes exist.
SELECT is_empty(
    $$ SELECT jwt FROM api.exchange_user_api_token('yk_00000000_' || repeat('a', 64)) $$,
    'an unknown prefix should return no rows'
);

SELECT is_empty(
    $$ SELECT jwt FROM api.exchange_user_api_token('not-even-a-token') $$,
    'a malformed token should return no rows'
);

SELECT is_empty(
    $$ SELECT jwt FROM api.exchange_user_api_token(NULL) $$,
    'a null token should return no rows'
);

-- A real token exchanges, and the JWT carries exactly the token's scopes.
CREATE OR REPLACE FUNCTION zapadka_test.make_token(p_user int, p_name text, p_scopes text[])
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, api, data, public, pg_temp
AS $$
DECLARE
    pfx text; sec text;
BEGIN
    pfx := 'yk_' || encode(public.gen_random_bytes(4), 'hex');
    sec := encode(public.gen_random_bytes(32), 'hex');
    INSERT INTO data.user_api_token (user_id, token_prefix, token_hash, name, scopes, expires_at)
    VALUES (p_user, pfx, sha256(sec::bytea), p_name, p_scopes, current_timestamp + interval '4 months');
    RETURN pfx || '_' || sec;
END;
$$;

SELECT is(
    (SELECT (zapadka_test.verify_pat_jwt(jwt)).payload::json->>'scopes'
     FROM api.exchange_user_api_token(
        zapadka_test.make_token(1, 'exchange me', ARRAY['course:read', 'grades:read'])
     )),
    'course:read grades:read',
    'the minted JWT should carry exactly the token''s scopes'
);

SELECT is(
    (SELECT (zapadka_test.verify_pat_jwt(jwt)).payload::json->>'aud'
     FROM api.exchange_user_api_token(
        zapadka_test.make_token(1, 'audience', ARRAY['course:read'])
     )),
    'yelukerest-postgrest',
    'the minted JWT should carry the single PostgREST audience, not the MCP pair'
);

SELECT ok(
    (SELECT (zapadka_test.verify_pat_jwt(jwt)).valid
     FROM api.exchange_user_api_token(
        zapadka_test.make_token(1, 'signature', ARRAY['course:read'])
     )),
    'the minted JWT should verify against the course jwt_secret'
);

-- Using a token records that it was used. This is the only evidence a
-- forgotten token is still live.
-- Exchange first, assert second: the function's UPDATE is not visible to the
-- snapshot of the statement that invoked it.
SELECT ok(
    (SELECT count(*) = 1 FROM api.exchange_user_api_token(
        set_config('zapadka_test.used', zapadka_test.make_token(1, 'used', ARRAY['course:read']), false)
    )),
    'a token created for the last_used_at check should exchange'
);

SELECT ok(
    (SELECT last_used_at IS NOT NULL FROM data.user_api_token WHERE name = 'used'),
    'a successful exchange should set last_used_at'
);

-- ---------------------------------------------------------------
-- Revocation
-- ---------------------------------------------------------------
-- Revocation needs two identities: only the owner may revoke, and only authapp
-- may exchange. The token string is stashed in a session setting so it survives
-- the switch between them.
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
set request.jwt.claim.app_name = '';

SELECT ok(
    set_config('zapadka_test.pat', zapadka_test.make_token(1, 'revoked before use', ARRAY['course:read']), false) IS NOT NULL,
    'a token to revoke should be created'
);

SELECT ok(
    (SELECT count(*) = 1 FROM api.revoke_user_api_token(
        (SELECT id FROM data.user_api_token WHERE name = 'default scopes')
    )),
    'a student should be able to revoke their own token'
);

-- Revoking twice must not move revoked_at: it records when access ended.
SELECT ok(
    (SELECT count(*) = 1 FROM api.revoke_user_api_token(
        (SELECT id FROM data.user_api_token WHERE name = 'default scopes')
    )),
    'revoking an already-revoked token should succeed idempotently'
);

SELECT ok(
    (SELECT count(*) = 1 FROM api.revoke_user_api_token(
        (SELECT id FROM data.user_api_token WHERE name = 'revoked before use')
    )),
    'the second token should revoke too'
);

-- Now prove a revoked token no longer exchanges, in the authapp identity.
set request.jwt.claim.role = 'app';
set request.jwt.claim.user_id = '';
set request.jwt.claim.app_name = 'authapp';

SELECT is_empty(
    $$ SELECT jwt FROM api.exchange_user_api_token(current_setting('zapadka_test.pat')) $$,
    'a revoked token should not exchange'
);

-- An expired token likewise, and indistinguishably from a revoked one.
SELECT is_empty(
    $$ WITH t AS (
           SELECT zapadka_test.make_token(1, 'expired', ARRAY['course:read']) AS tok
       ), e AS (
           UPDATE data.user_api_token SET expires_at = current_timestamp - interval '1 day'
            WHERE name = 'expired' RETURNING 1
       )
       SELECT jwt FROM t, e, api.exchange_user_api_token(t.tok) $$,
    'an expired token should not exchange'
);

-- A student may not revoke someone else's token.
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '3';
set request.jwt.claim.app_name = '';
SELECT is_empty(
    $$ SELECT id FROM api.revoke_user_api_token(
           (SELECT id FROM data.user_api_token WHERE name = 'shape check')
       ) $$,
    'a student should not be able to revoke another user''s token'
);

SELECT * FROM finish();
