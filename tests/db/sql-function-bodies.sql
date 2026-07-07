begin;
select plan(1);

SELECT set_eq(
    $$
        SELECT n.nspname || '.' || p.proname
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE (n.nspname, p.proname) IN (
            ('auth', 'sign_jwt'),
            ('data', 'text_is_url'),
            ('data', 'text_matches'),
            ('request', 'app_name'),
            ('request', 'user_id'),
            ('request', 'user_id_as_text'),
            ('request', 'user_role'),
            ('settings', 'get'),
            ('settings', 'set')
        )
        AND p.prosqlbody IS NOT NULL
    $$,
    ARRAY[
        'auth.sign_jwt',
        'data.text_is_url',
        'data.text_matches',
        'request.app_name',
        'request.user_id',
        'request.user_id_as_text',
        'request.user_role',
        'settings.get',
        'settings.set'
    ],
    'project-owned SQL helper functions should use parsed SQL bodies'
);

select * from finish();
rollback;
