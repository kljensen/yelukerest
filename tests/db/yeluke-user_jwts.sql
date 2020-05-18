begin;
select plan(7);

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

set local role anonymous;
set request.jwt.claim.role = 'anonymous';
SELECT throws_ok(
    'select (id) from api.user_jwts',
    '42501',
    'permission denied for relation user_jwts',
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
SELECT set_eq(
    'SELECT (id) FROM api.user_jwts ORDER BY id',
    ARRAY[1,2,3,4,5],
    'ta should be able to select from the api.user_jwts view'
);

select * from finish();
rollback;
