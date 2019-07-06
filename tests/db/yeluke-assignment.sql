begin;
select plan(11);

SELECT view_owner_is(
    'api', 'assignments', 'api',
    'api.assignments view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignments', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.assignments"'
);

SELECT table_privs_are(
    'api', 'assignments', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.assignments"'
);

SELECT table_privs_are(
    'data', 'quiz', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select * from api.assignments',
    '%permission denied%',
    'anonymous users should not be able to use the api.assignments view'
);

set local role student;
set request.jwt.claim.role = 'student';

SELECT set_eq(
    'SELECT slug FROM api.assignments ORDER BY (slug)',
    ARRAY['exam-1', 'js-koans', 'project-update-1', 'team-selection'],
    'students should be able to select from the api.assignments view'
);

PREPARE doinsert AS INSERT INTO api.assignments (slug,points_possible,title,body,closed_at) VALUES ('foo', 23, 'foo', 'foo', '2017-12-27 14:55:50');
PREPARE badinsert1 AS INSERT INTO api.assignments (slug,points_possible,title,body,closed_at) VALUES ('fooX', 23, 'foo', 'foo', '2017-12-27 14:55:50');
PREPARE badinsert2 AS INSERT INTO api.assignments (slug,points_possible,title,body,closed_at) VALUES ('abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789XX', 23, 'foo', 'foo', '2017-12-27 14:55:50');

SELECT throws_like(
    'doinsert',
    '%permission denied%',
    'students should not be able to insert'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT lives_ok(
    'doinsert',
    'faculty should be able to insert'
);

SELECT lives_ok(
    'DELETE FROM api.assignments WHERE slug = ''foo''',
    'faculty can delete assignments'
);

SELECT throws_like(
    'badinsert1',
    '%violates check constraint%',
    'assignment slugs must be lowercase alphanumeric'
);

SELECT throws_like(
    'badinsert2',
    '%violates check constraint%',
    'assignment slugs must be less than 60 characters'
);

select * from finish();
rollback;
