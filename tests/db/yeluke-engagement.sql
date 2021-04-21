begin;
select plan(5);

SELECT view_owner_is(
    'api', 'engagements', 'api',
    'api.engagements view should be owned by the api role'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_ok(
    'select (user_id, meeting_slug) from api.engagements',
    '42501',
    'permission denied for view engagements',
    'anonymous users should not be able to use the api.engagements view'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT lives_ok(
    'select (user_id, meeting_slug) from api.engagements',
    'faculty should be able to select from the api.engagements view'
);

SELECT set_eq(
    'SELECT user_id FROM api.engagements ORDER BY (meeting_slug, user_id)',
    ARRAY[1, 2, 3, 1, 2, 3, 1, 2, 3],
    'faculty should be able to select from the api.engagements view'
);


set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT user_id FROM api.engagements ORDER BY (meeting_slug, user_id)',
    ARRAY[1, 1, 1],
    'students should only be able to see their own rows in the api.engagements view'
);

select * from finish();
rollback;
