begin;
select plan(11);

SELECT view_owner_is(
    'api', 'assignment_grades', 'api',
    'api.assignment_grades view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignment_grades', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.assignment_grades"'
);

SELECT table_privs_are(
    'api', 'assignment_grades', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.assignment_grades"'
);

SELECT table_privs_are(
    'data', 'assignment_grade', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.assignment_grade"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select * from api.assignment_grades',
    '%permission denied%',
    'anonymous users should not be able to use the api.assignment_grades view'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';


SELECT set_eq(
    'SELECT assignment_submission_id FROM api.assignment_grades',
    ARRAY[1, 4],
    'students should be able to see assignment grades for only themselves and their team'
);

SELECT throws_like(
    'UPDATE api.assignment_grades SET points=12 WHERE assignment_submission_id = 1',
    '%permission denied%',
    'students should NOT be able to alter their assignment grades'
);


set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    'SELECT assignment_submission_id FROM api.assignment_grades',
    ARRAY[1, 2, 3, 4],
    'faculty should be able to see all assignment grades'
);

SELECT lives_ok(
    'UPDATE api.assignment_grades SET points=12 WHERE assignment_submission_id = 1',
    'faculty should be able to alter assignment grades'
);

SELECT throws_like(
    'UPDATE api.assignment_grades SET points=100000 WHERE assignment_submission_id = 1',
    '%constraint%',
    'are limited to the point range of the assignment'
);

SELECT throws_like(
    'INSERT INTO api.assignment_grades (assignment_submission_id, assignment_slug, points) VALUES (10, ''team-selection'', 13)',
    '%violates foreign key%',
    'cannot have a grade for an assignment where there is no submission'
);


select * from finish();
rollback;
