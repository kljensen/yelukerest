begin;
select plan(10);

SELECT view_owner_is(
    'api', 'grades', 'api',
    'api.grades view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'grades', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.grades"'
);

SELECT table_privs_are(
    'api', 'grades', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.grades"'
);

SELECT table_privs_are(
    'data', 'grade', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.grade"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select * from api.grades',
    '%permission denied%',
    'anonymous users should not be able to use the api.grades view'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT user_id FROM api.grades',
    ARRAY[1],
    'students should be able to see their own grades'
);

SELECT throws_like(
    'UPDATE api.grades SET points=12 WHERE user_id = 1',
    '%permission denied%',
    'students should NOT be able to alter their grades'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    'SELECT user_id FROM api.grades',
    ARRAY[1, 2, 4, 5],
    'faculty should be able to see all grades'
);

SELECT lives_ok(
    'UPDATE api.grades SET points=10 WHERE user_id = 1',
    'faculty should be able to alter grades'
);

SELECT throws_like(
    $$INSERT INTO api.grades(user_id, snapshot_slug, points) VALUES(1, 'after-first-exam', 1) $$,
    '%violates unique constraint%',
    'users should only have one grade per snapshot'
);



set local role faculty;
set request.jwt.claim.role = 'faculty';

select * from finish();
rollback;
