begin;
select plan(3);

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

select * from finish();
rollback;
