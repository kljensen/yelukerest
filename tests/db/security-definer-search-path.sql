begin;
select plan(12);

SELECT is(
    (
        SELECT count(*)::int
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'settings'
        AND p.proname = 'get'
        AND p.proconfig @> ARRAY['search_path=pg_catalog, settings, pg_temp']
    ),
    1,
    'settings.get should pin its security-definer search_path'
);

SELECT is(
    (
        SELECT count(*)::int
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'settings'
        AND p.proname = 'set'
        AND p.proconfig @> ARRAY['search_path=pg_catalog, settings, pg_temp']
    ),
    1,
    'settings.set should pin its security-definer search_path'
);

SELECT is(
    (
        SELECT count(*)::int
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'auth'
        AND p.proname = 'sign_jwt'
        AND p.proconfig @> ARRAY['search_path=pg_catalog, auth, settings, pgjwt, pg_temp']
    ),
    1,
    'auth.sign_jwt should pin its security-definer search_path'
);

SELECT is(
    has_function_privilege('api', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE'),
    true,
    'api should be able to execute auth.sign_jwt'
);

SELECT is(
    has_function_privilege('student', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE'),
    true,
    'student should be able to execute auth.sign_jwt through api.user_jwts'
);

SELECT is(
    has_function_privilege('ta', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE'),
    true,
    'ta should be able to execute auth.sign_jwt through api.user_jwts'
);

SELECT is(
    has_function_privilege('faculty', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE'),
    true,
    'faculty should be able to execute auth.sign_jwt through api.user_jwts'
);

SELECT is(
    has_function_privilege('app', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE'),
    true,
    'app should be able to execute auth.sign_jwt through api.user_jwts'
);

SELECT is(
    has_schema_privilege('student', 'auth', 'USAGE'),
    false,
    'student should not have direct usage on auth schema'
);

SELECT is(
    has_schema_privilege('ta', 'auth', 'USAGE'),
    false,
    'ta should not have direct usage on auth schema'
);

SELECT is(
    has_schema_privilege('faculty', 'auth', 'USAGE'),
    false,
    'faculty should not have direct usage on auth schema'
);

SELECT is(
    has_schema_privilege('app', 'auth', 'USAGE'),
    false,
    'app should not have direct usage on auth schema'
);

select * from finish();
rollback;
