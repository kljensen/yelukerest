-- Verify bound-api-token-lifetime-and-count.
--
-- Runs READ ONLY, and re-runs against every later state of the database, so it
-- asserts invariants rather than the shape of the data at deploy time. The
-- behaviour -- which expiries are refused, and with what message -- is covered
-- by tests/db/yeluke-user_api_token.sql, which can write.
--
-- The `1 / count(*)` idiom raises division_by_zero when the expected thing is
-- missing, which is what fails the verify.

-- The lifetime backstop is on the table.
SELECT 1 / count(*)::int FROM pg_constraint
 WHERE conrelid = 'data.user_api_token'::regclass
   AND contype = 'c'
   AND conname = 'user_api_token_max_lifetime';

-- ...and no row escapes it. True at deploy because deploy.sql capped the
-- over-long rows, and true afterwards because the constraint is what keeps it
-- true.
SELECT 1 / (
    SELECT (count(*) = 0)::int FROM data.user_api_token
     WHERE expires_at > created_at + interval '180 days'
)::int;

-- The creating RPC is still the narrow, privileged thing it has to be for the
-- bound above to mean anything: a person cannot reach the table any other way,
-- because api.user_api_tokens carries no INSERT grant.
SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api'
       AND p.proname = 'create_user_api_token'
       AND p.prosecdef
);

SELECT 1 / (
    SELECT (NOT has_function_privilege(
        'public',
        'api.create_user_api_token(text, text[], timestamp with time zone)',
        'EXECUTE'
    ))::int
);

SELECT 1 / (
    SELECT has_function_privilege(
        'student',
        'api.create_user_api_token(text, text[], timestamp with time zone)',
        'EXECUTE'
    )::int
);

SELECT 1 / (
    SELECT (count(*) = 0)::int FROM information_schema.role_table_grants
     WHERE table_schema = 'api' AND table_name = 'user_api_tokens'
       AND grantee IN ('student', 'ta', 'faculty')
       AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE')
)::int;
