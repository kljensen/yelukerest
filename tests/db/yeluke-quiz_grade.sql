begin;
select plan(11);

SELECT view_owner_is(
    'api', 'quiz_grades', 'api',
    'api.quiz_grades view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'quiz_grades', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.quiz_grades"'
);

SELECT table_privs_are(
    'api', 'quiz_grades', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.quiz_grades"'
);

SELECT table_privs_are(
    'data', 'quiz_grade', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz_grade"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select quiz_id from api.quiz_grades',
    '%permission denied%',
    'anonymous users should not be able to use the api.quiz_grades view'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';


SELECT set_eq(
    'SELECT quiz_id FROM api.quiz_grades',
    ARRAY[1],
    'students should be able to see their own quiz grades'
);

SELECT throws_like(
    'UPDATE api.quiz_grades SET points=12 WHERE quiz_id = 1',
    '%permission denied%',
    'students should NOT be able to alter their quiz grades'
);


set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    'SELECT quiz_id FROM api.quiz_grades',
    ARRAY[1, 1],
    'faculty should be able to see all quiz grades'
);

SELECT lives_ok(
    'UPDATE api.quiz_grades SET points=12 WHERE quiz_id = 1',
    'faculty should be able to alter quiz grades'
);

SELECT throws_like(
    'UPDATE api.quiz_grades SET points=100000 WHERE quiz_id = 1',
    '%constraint%',
    'are limited to the point range of the quiz'
);

SELECT throws_like(
    'INSERT INTO api.quiz_grades (quiz_id, user_id, points) VALUES (1, 3, 13)',
    '%violates foreign key%',
    'cannot have a grade for a quiz where there is no submission'
);


select * from finish();
rollback;
