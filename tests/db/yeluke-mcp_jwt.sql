-- Tests for the dedicated mcpapp service minting path (issue #263):
-- api.issue_user_jwt_for_mcp, the data.mcp_jwt_mint_event append-only
-- audit table, the faculty-only api.mcp_jwt_mint_events view, and the
-- api.mcp_jwt_mint_anomalies mint-rate report.
select * from no_plan();

create or replace function zapadka_test.verify_jwt(jwt text) RETURNS TABLE(header json, payload json, valid boolean)
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
    'api', 'mcp_jwt_mint_events', 'api',
    'api.mcp_jwt_mint_events view should be owned by the api role'
);

SELECT view_owner_is(
    'api', 'mcp_jwt_mint_anomalies', 'api',
    'api.mcp_jwt_mint_anomalies view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'mcp_jwt_mint_events', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on view "api.mcp_jwt_mint_events"'
);

SELECT table_privs_are(
    'api', 'mcp_jwt_mint_events', 'student', ARRAY[]::TEXT[],
    'student should not be granted privileges on view "api.mcp_jwt_mint_events"'
);

SELECT table_privs_are(
    'api', 'mcp_jwt_mint_events', 'ta', ARRAY[]::TEXT[],
    'ta should not be granted privileges on view "api.mcp_jwt_mint_events"'
);

SELECT table_privs_are(
    'api', 'mcp_jwt_mint_events', 'app', ARRAY[]::TEXT[],
    'app should not be granted privileges on view "api.mcp_jwt_mint_events"'
);

SELECT table_privs_are(
    'api', 'mcp_jwt_mint_anomalies', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on view "api.mcp_jwt_mint_anomalies"'
);

SELECT table_privs_are(
    'api', 'mcp_jwt_mint_anomalies', 'student', ARRAY[]::TEXT[],
    'student should not be granted privileges on view "api.mcp_jwt_mint_anomalies"'
);

SELECT function_privs_are(
    'api', 'issue_user_jwt_for_mcp', ARRAY['text', 'text[]', 'jsonb'], 'app', ARRAY['EXECUTE'],
    'app should only be granted EXECUTE on function "api.issue_user_jwt_for_mcp"'
);

SELECT function_privs_are(
    'api', 'issue_user_jwt_for_mcp', ARRAY['text', 'text[]', 'jsonb'], 'student', ARRAY[]::TEXT[],
    'student should not be granted EXECUTE on function "api.issue_user_jwt_for_mcp"'
);

SELECT function_privs_are(
    'api', 'issue_user_jwt_for_mcp', ARRAY['text', 'text[]', 'jsonb'], 'anonymous', ARRAY[]::TEXT[],
    'anonymous should not be granted EXECUTE on function "api.issue_user_jwt_for_mcp"'
);

SELECT is(
    (
        SELECT count(*)::int
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api'
        AND p.proname = 'issue_user_jwt_for_mcp'
        AND p.prosecdef
        AND p.proconfig @> ARRAY['search_path=pg_catalog, api, auth, data, request, settings, pg_temp']
    ),
    1,
    'api.issue_user_jwt_for_mcp should pin its security-definer search_path'
);

SELECT is(
    (
        SELECT count(*)::int
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'auth'
        AND p.proname = 'sign_mcp_user_jwt'
        AND p.prosecdef
        AND p.proconfig @> ARRAY['search_path=pg_catalog, auth, settings, pgjwt, pg_temp']
    ),
    1,
    'auth.sign_mcp_user_jwt should pin its security-definer search_path'
);

SELECT is(
    has_function_privilege('app', 'auth.sign_mcp_user_jwt(integer, data.user_role, text, text, text)', 'EXECUTE'),
    false,
    'app should not be able to execute auth.sign_mcp_user_jwt directly'
);

-- The two service minting paths are independently revocable.
REVOKE EXECUTE ON FUNCTION api.issue_user_jwt(text) FROM app;
SELECT is(
    has_function_privilege('app', 'api.issue_user_jwt(text)', 'EXECUTE'),
    false,
    'the authapp minting grant can be revoked on its own'
);
SELECT is(
    has_function_privilege('app', 'api.issue_user_jwt_for_mcp(text, text[], jsonb)', 'EXECUTE'),
    true,
    'revoking the authapp minting grant does not affect the MCP minting grant'
);
GRANT EXECUTE ON FUNCTION api.issue_user_jwt(text) TO app;

-- ---------------------------------------------------------------
-- Caller admission: only app_name=mcpapp may mint
-- ---------------------------------------------------------------
set local role app;
set request.jwt.claim.role = 'app';
set request.jwt.claim.user_id = '';
set request.jwt.claim.app_name = 'authapp';

SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('abc123', ARRAY['course:read']) $$,
    '%mcpapp%',
    'the authapp credential should not be able to mint MCP user JWTs'
);

set request.jwt.claim.app_name = 'fooapp';
SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('abc123', ARRAY['course:read']) $$,
    '%mcpapp%',
    'other app credentials should not be able to mint MCP user JWTs'
);

-- The authapp path still works and is unchanged by the MCP path.
set request.jwt.claim.app_name = 'authapp';
SELECT set_eq(
    $$
        SELECT (zapadka_test.verify_jwt(jwt)).payload::json->>'user_id' FROM api.issue_user_jwt('abc123');
    $$,
    ARRAY['1'],
    'the authapp should still mint user jwts through the issue_user_jwt RPC'
);

-- ---------------------------------------------------------------
-- mcpapp can mint: claims, TTL, scopes, and the audit row
-- ---------------------------------------------------------------
set request.jwt.claim.app_name = 'mcpapp';

CREATE TEMPORARY TABLE minted_jwt AS
    SELECT *
    FROM api.issue_user_jwt_for_mcp(
        'abc123',
        ARRAY['course:read', 'grades:read'],
        '{"iss": "https://hydra.example.edu", "sub": "cas|abc123", "jti": "ext-jti-001", "client_id": "client-abc"}'::jsonb
    );

SELECT is(
    (SELECT count(*)::int FROM minted_jwt),
    1,
    'the mcpapp should mint exactly one JWT per call'
);

SELECT results_eq(
    $$ SELECT user_id, netid, "role" FROM minted_jwt $$,
    $$ VALUES (1, 'abc123'::text, 'student'::text) $$,
    'the mint RPC should return the minted-for user id, netid, and role'
);

SELECT is(
    (SELECT (zapadka_test.verify_jwt(jwt)).valid FROM minted_jwt),
    true,
    'the minted MCP JWT should be signed with the configured secret'
);

SELECT results_eq(
    $$
        SELECT
            payload->>'iss' AS issuer,
            -- Array audience: mcpapp accepts the token AND can forward it
            -- to PostgREST, which requires its own audience.
            (payload->'aud')::jsonb::text AS audience,
            payload->>'sub' AS subject,
            payload->>'user_id' AS user_id,
            payload->>'role' AS role,
            payload->>'netid' AS netid,
            payload->>'scopes' AS scopes
        FROM (SELECT (zapadka_test.verify_jwt(jwt)).payload::json AS payload FROM minted_jwt) t
    $$,
    $$
        VALUES (
            'yelukerest'::text,
            '["yelukerest-postgrest", "yelukerest-mcp"]'::jsonb::text,
            'user:1'::text,
            '1'::text,
            'student'::text,
            'abc123'::text,
            'course:read grades:read'::text
        )
    $$,
    'the minted MCP JWT should carry the standard claims plus space-separated scopes and netid'
);

SELECT isnt_empty(
    $$
        SELECT 1
        FROM minted_jwt
        CROSS JOIN LATERAL zapadka_test.verify_jwt(jwt) verified
        WHERE (verified.payload::json->>'iat')::integer <= extract(epoch from now())::integer
        AND (verified.payload::json->>'nbf')::integer <= extract(epoch from now())::integer
        AND (verified.payload::json->>'exp')::integer > extract(epoch from now())::integer
        AND (verified.payload::json->>'exp')::integer - (verified.payload::json->>'iat')::integer = 600
    $$,
    'minted MCP JWTs should have valid iat/nbf/exp claims and a 10-minute TTL'
);

SELECT isnt_empty(
    $$
        SELECT 1
        FROM minted_jwt
        CROSS JOIN LATERAL zapadka_test.verify_jwt(jwt) verified
        WHERE (verified.payload::json->>'jti') ~ '^[0-9a-f-]{36}$'
    $$,
    'minted MCP JWTs should include a token id'
);

-- Unknown netids mint nothing (mirrors issue_user_jwt's empty result).
SELECT is_empty(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('nosuchnetid', ARRAY['course:read']) $$,
    'unknown netids should not be minted MCP JWTs'
);

-- Observers are outside the default role allowlist.
SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('crt43', ARRAY['course:read']) $$,
    '%not mintable%',
    'observers should not be mintable with the default allowlist'
);

-- Faculty are mintable by default (needed for the pilot).
SELECT set_eq(
    $$
        SELECT (zapadka_test.verify_jwt(jwt)).payload::json->>'role' FROM api.issue_user_jwt_for_mcp('klj39', ARRAY['course:read'])
    $$,
    ARRAY['faculty'],
    'faculty should be mintable with the default allowlist'
);

-- Scope input bounds.
SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('abc123', ARRAY[]::text[]) $$,
    '%scopes are required%',
    'an empty scope list should be rejected'
);

SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('abc123', NULL::text[]) $$,
    '%scopes are required%',
    'a null scope list should be rejected'
);

SELECT throws_like(
    $$
        SELECT * FROM api.issue_user_jwt_for_mcp(
            'abc123',
            (SELECT array_agg('scope:' || i) FROM generate_series(1, 17) i)
        )
    $$,
    '%scopes are required%',
    'more than 16 scopes should be rejected'
);

SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('abc123', ARRAY['bad scope!']) $$,
    '%malformed scope%',
    'malformed scopes should be rejected'
);

-- NULL array elements must be rejected explicitly: `scope !~ pattern`
-- is NULL for a NULL element, so without an IS NULL test the value
-- passes validation and is then dropped silently by array_to_string,
-- minting a token whose scopes differ from those requested.
SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('abc123', ARRAY[NULL, 'course:read']::text[]) $$,
    '%malformed scope%',
    'a NULL scope element should be rejected'
);

SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('abc123', ARRAY[NULL]::text[]) $$,
    '%malformed scope%',
    'an all-NULL scope array should be rejected as malformed, not by a downstream constraint'
);

SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp(repeat('x', 100), ARRAY['course:read']) $$,
    '%invalid netid%',
    'oversized netids should be rejected'
);

-- ---------------------------------------------------------------
-- The course operator can tighten the mintable-role allowlist
-- ---------------------------------------------------------------
reset role;
SELECT settings.set('mcp_mintable_roles', 'student,ta');

set local role app;
SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('klj39', ARRAY['course:read']) $$,
    '%not mintable%',
    'faculty should not be mintable after the allowlist is tightened'
);

SELECT set_eq(
    $$
        SELECT (zapadka_test.verify_jwt(jwt)).payload::json->>'user_id' FROM api.issue_user_jwt_for_mcp('bde456', ARRAY['course:read'])
    $$,
    ARRAY['2'],
    'students should still be mintable after the allowlist is tightened'
);

reset role;
SELECT settings.set('mcp_mintable_roles', 'student,ta,faculty');

-- ---------------------------------------------------------------
-- Audit rows: every successful mint is recorded, in-transaction
-- ---------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM data.mcp_jwt_mint_event),
    3,
    'each successful mint (and nothing else) should append one audit row'
);

SELECT results_eq(
    $$
        SELECT user_id, netid, user_role, scopes, caller_app_name,
               external_issuer, external_sub, external_jti, external_client_id
        FROM data.mcp_jwt_mint_event
        WHERE netid = 'abc123'
    $$,
    $$
        VALUES (
            1, 'abc123'::text, 'student'::text, 'course:read grades:read'::text, 'mcpapp'::text,
            'https://hydra.example.edu'::text, 'cas|abc123'::text, 'ext-jti-001'::text, 'client-abc'::text
        )
    $$,
    'the audit row should record subject, role, scopes, caller, and the external token identity'
);

SELECT set_eq(
    $$ SELECT jti FROM data.mcp_jwt_mint_event WHERE netid = 'abc123' $$,
    $$ SELECT (zapadka_test.verify_jwt(jwt)).payload::json->>'jti' FROM minted_jwt $$,
    'the audit row jti should match the jti of the minted JWT'
);

SELECT set_eq(
    $$
        SELECT external_issuer FROM data.mcp_jwt_mint_event WHERE netid = 'klj39'
    $$,
    ARRAY[NULL::text],
    'external token fields should be null when no external identity is supplied'
);

SELECT isnt_empty(
    $$
        SELECT 1 FROM data.mcp_jwt_mint_event
        WHERE created_at > now() - '1 minute'::interval
        AND created_at <= now()
    $$,
    'audit rows should be stamped with the mint time'
);

-- Append-only enforcement.
SELECT throws_like(
    $$ UPDATE data.mcp_jwt_mint_event SET netid = 'tampered' WHERE netid = 'abc123' $$,
    '%append-only%',
    'mint audit rows should reject UPDATE'
);

SELECT throws_like(
    $$ DELETE FROM data.mcp_jwt_mint_event WHERE netid = 'abc123' $$,
    '%append-only%',
    'mint audit rows should reject DELETE'
);

-- ---------------------------------------------------------------
-- Only faculty can read the audit history
-- ---------------------------------------------------------------
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
set request.jwt.claim.app_name = '';

SELECT throws_like(
    'SELECT * FROM api.mcp_jwt_mint_events',
    '%permission denied%',
    'students should not be able to read the mint audit history'
);

SELECT throws_like(
    'SELECT * FROM api.mcp_jwt_mint_anomalies',
    '%permission denied%',
    'students should not be able to read the mint anomaly report'
);

SELECT throws_like(
    $$ SELECT * FROM api.issue_user_jwt_for_mcp('abc123', ARRAY['course:read']) $$,
    '%permission denied%',
    'students should not be able to call the MCP mint RPC'
);

set local role ta;
set request.jwt.claim.role = 'ta';
set request.jwt.claim.user_id = '4';

SELECT throws_like(
    'SELECT * FROM api.mcp_jwt_mint_events',
    '%permission denied%',
    'tas should not be able to read the mint audit history'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';

SELECT set_eq(
    'SELECT netid FROM api.mcp_jwt_mint_events',
    ARRAY['abc123', 'klj39', 'bde456'],
    'faculty should be able to read the full mint audit history'
);

-- ---------------------------------------------------------------
-- Mint-rate anomaly report
-- ---------------------------------------------------------------
reset role;

-- Synthetic compromise: one caller mints for 12 distinct subjects
-- inside a single 10-minute window, and another stays below the
-- threshold within its window.
INSERT INTO data.mcp_jwt_mint_event
    (user_id, netid, user_role, scopes, jti, caller_app_name, created_at)
SELECT
    100 + i,
    'synth' || i,
    'student',
    'course:read',
    public.gen_random_uuid()::text,
    'synthetic-mcp',
    '2030-01-01 00:05:00+00'::timestamptz
FROM generate_series(1, 12) i;

INSERT INTO data.mcp_jwt_mint_event
    (user_id, netid, user_role, scopes, jti, caller_app_name, created_at)
SELECT
    200 + i,
    'quiet' || i,
    'student',
    'course:read',
    public.gen_random_uuid()::text,
    'quiet-mcp',
    '2030-01-01 00:05:00+00'::timestamptz
FROM generate_series(1, 3) i;

-- A burst that straddles a fixed-bucket boundary: six subjects just
-- before :10 and six just after. Fixed epoch buckets would see only six
-- in each bucket and miss it; the sliding window must catch it.
INSERT INTO data.mcp_jwt_mint_event
    (user_id, netid, user_role, scopes, jti, caller_app_name, created_at)
SELECT
    300 + i,
    'straddle' || i,
    'student',
    'course:read',
    public.gen_random_uuid()::text,
    'straddle-mcp',
    CASE WHEN i <= 6
        THEN '2030-02-01 00:09:00+00'::timestamptz
        ELSE '2030-02-01 00:11:00+00'::timestamptz
    END
FROM generate_series(1, 12) i;

set local role faculty;

SELECT is(
    (SELECT count(DISTINCT caller_app_name)::int FROM api.mcp_jwt_mint_anomalies),
    2,
    'the anomaly report should flag both the in-window burst and the boundary-straddling burst'
);

SELECT is(
    (SELECT max(distinct_subjects)::int FROM api.mcp_jwt_mint_anomalies
     WHERE caller_app_name = 'synthetic-mcp'),
    12,
    'the anomaly report should count all 12 subjects minted inside one window'
);

SELECT is(
    (SELECT max(distinct_subjects)::int FROM api.mcp_jwt_mint_anomalies
     WHERE caller_app_name = 'straddle-mcp'),
    12,
    'a burst straddling a fixed-bucket boundary should still be flagged'
);

SELECT is(
    (SELECT count(*)::int FROM api.mcp_jwt_mint_anomalies
     WHERE caller_app_name = 'quiet-mcp'),
    0,
    'callers below the threshold should not be flagged'
);

-- ---------------------------------------------------------------
-- The scopes claim round-trips through the request context
-- ---------------------------------------------------------------
reset role;
set request.jwt.claims = '{"scopes": "course:read grades:read"}';

SELECT is(
    request.jwt_claim('scopes'),
    'course:read grades:read',
    'the scopes claim should be readable back through request.jwt_claim'
);

select * from finish();
