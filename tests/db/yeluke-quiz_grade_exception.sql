begin;
select plan(9);

SELECT view_owner_is(
    'api', 'quiz_grade_exceptions', 'api',
    'api.quiz_grade_exceptions view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'quiz_grade_exceptions', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.quiz_grade_exceptions"'
);

SELECT table_privs_are(
    'api', 'quiz_grade_exceptions', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.quiz_grade_exceptions"'
);

SELECT table_privs_are(
    'data', 'quiz_grade_exception', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz_grade_exception"'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.quiz_grade_exceptions',
    ARRAY[0],
    'students shoud not be able to see quiz_grade_exceptions for other students'
);

set request.jwt.claim.user_id = '5';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.quiz_grade_exceptions',
    ARRAY[1],
    'students shoud be able to see quiz_grade_exceptions of their own'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
PREPARE startquiz AS INSERT INTO api.quiz_submissions (quiz_id, user_id) VALUES($1, $2);
UPDATE api.quizzes SET is_draft=TRUE;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '5';
SELECT throws_like(
    'EXECUTE startquiz(1, 5)', 
    '%violates row-level security policy%',
    'students should NOT be able to create quiz submissions for a closed quiz if they have an exception but the quiz is draft'
);


set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.quizzes SET is_draft=FALSE;
UPDATE api.quizzes SET closed_at = current_timestamp - '1 hour'::INTERVAL WHERE id=1;
UPDATE api.quiz_grade_exceptions SET closed_at = current_timestamp - '1 hour'::INTERVAL;
SELECT throws_like(
    'EXECUTE startquiz(1, 5)', 
    '%violates row-level security policy%',
    'students should NOT be able to create quiz submissions with an expired exception'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.quiz_grade_exceptions SET closed_at = current_timestamp + '1 hour'::INTERVAL;

SELECT lives_ok(
    'EXECUTE startquiz(1, 5)', 
    'students should be able to create quiz submissions for a closed quiz if they have an exception but the quiz is draft'
);


select * from finish();
rollback;
