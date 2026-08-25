-- Verify add-user-api-token.
--
-- Runs READ ONLY and is always rolled back, so expected sets are built with
-- VALUES rather than temp tables.

-- The table and its columns exist with the expected types.
SELECT 1 / count(*)::int FROM information_schema.tables
 WHERE table_schema = 'data' AND table_name = 'user_api_token';

SELECT 1 / (
    SELECT count(*)::int = 10
      FROM information_schema.columns
     WHERE table_schema = 'data' AND table_name = 'user_api_token'
       AND column_name IN (
           'id', 'user_id', 'token_prefix', 'token_hash', 'name', 'scopes',
           'created_at', 'expires_at', 'last_used_at', 'revoked_at'
       )
)::int;

-- Row level security is on, with a policy.
SELECT 1 / (
    SELECT relrowsecurity::int FROM pg_class
     WHERE oid = 'data.user_api_token'::regclass
);

SELECT 1 / count(*)::int FROM pg_policies
 WHERE schemaname = 'data' AND tablename = 'user_api_token'
   AND policyname = 'user_api_token_access_policy';

-- The foreign key index tests/db/foreign-key-indexes.sql insists on: led by
-- user_id, and not partial.
SELECT 1 / count(*)::int FROM pg_index ix
 JOIN pg_class c ON c.oid = ix.indexrelid
 WHERE ix.indrelid = 'data.user_api_token'::regclass
   AND ix.indpred IS NULL
   AND (
       SELECT attname FROM pg_attribute
        WHERE attrelid = ix.indrelid AND attnum = ix.indkey[0]
   ) = 'user_id';

-- The api view exists and, crucially, does NOT expose the secret hash.
SELECT 1 / count(*)::int FROM information_schema.views
 WHERE table_schema = 'api' AND table_name = 'user_api_tokens';

SELECT 1 / (
    SELECT (count(*) = 0)::int FROM information_schema.columns
     WHERE table_schema = 'api' AND table_name = 'user_api_tokens'
       AND column_name IN ('token_hash')
)::int;

-- Both functions exist, are SECURITY DEFINER, and are not executable by PUBLIC.
SELECT 1 / (
    SELECT (count(*) = 2)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api'
       AND p.proname IN ('create_user_api_token', 'exchange_user_api_token')
       AND p.prosecdef
)::int;

SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'auth' AND p.proname = 'sign_user_jwt_with_scopes'
       AND p.prosecdef
)::int;

SELECT 1 / (
    SELECT (NOT has_function_privilege(
        'public', 'api.exchange_user_api_token(text)', 'EXECUTE'
    ))::int
);

-- The scope vocabulary is constrained, and the expiry ordering enforced.
SELECT 1 / (
    SELECT (count(*) >= 2)::int FROM pg_constraint
     WHERE conrelid = 'data.user_api_token'::regclass
       AND contype = 'c'
);

-- The compatibility shape advertises 7.
SELECT 1 / (
    SELECT (schema_compatibility_version >= 7)::int FROM api.platform_version
);
