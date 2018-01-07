begin;
select plan(15);

SELECT view_owner_is(
    'api', 'quiz_submissions', 'api',
    'api.quiz_submissions view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'quiz_submissions', 'student', ARRAY['SELECT', 'INSERT'],
    'student should only be granted SELECT, INSERT on view "api.quiz_submissions"'
);

SELECT table_privs_are(
    'api', 'quiz_submissions', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.quiz_submissions"'
);

SELECT table_privs_are(
    'data', 'quiz', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz_question"'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    'SELECT quiz_id FROM api.quiz_submissions ORDER BY (quiz_id)',
    ARRAY[1, 1],
    'faculty should be able to see all quiz submissions'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT quiz_id FROM api.quiz_submissions ORDER BY (quiz_id)',
    ARRAY[1],
    'students shoud only be able to see their own quiz submissions (user 1)'
);

set request.jwt.claim.user_id = '3';

SELECT set_eq(
    'SELECT quiz_id FROM api.quiz_submissions ORDER BY (quiz_id)',
    ARRAY[]::integer[],
    'students shoud only be able to see their own quiz submissions (user 3)'
);

PREPARE startquiz AS INSERT INTO api.quiz_submissions (quiz_id, user_id) VALUES($1, $2);



SELECT throws_ok(
    'EXECUTE startquiz(1, 3)', -- Quiz 1 is closed
    '42501',
    'new row violates row-level security policy for table "quiz_submission"',
    'students should not be able to create a quiz submission after the quiz is closed'
);

SELECT throws_ok(
    'EXECUTE startquiz(3, 3)', -- Quiz 3 is in draft mode
    '42501',
    'new row violates row-level security policy for table "quiz_submission"',
    'students should not be able to create quiz submissions if quiz is draft'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.quizzes SET open_at = current_timestamp + '1 hour' WHERE id=2;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '3';

SELECT throws_ok(
    'EXECUTE startquiz(2, 3)', -- Quiz 3 is in draft mode in the sample data
    '42501',
    'new row violates row-level security policy for table "quiz_submission"',
    'students should not be able to create quiz submissions if quiz is not yet open'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.quizzes SET
    open_at = (current_timestamp - '1 hour'::INTERVAL),
    closed_at = (current_timestamp - '30 minutes'::INTERVAL)
    WHERE id=2;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '3';

SELECT throws_ok(
    'EXECUTE startquiz(2, 3)', 
    '42501',
    'new row violates row-level security policy for table "quiz_submission"',
    'students should not be able to create quiz submissions if quiz is closed already'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.quizzes SET
    open_at = (current_timestamp - '1 hour'::INTERVAL),
    closed_at = (current_timestamp + '30 minutes'::INTERVAL)
    WHERE id=2;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '3';

SELECT throws_ok(
    'EXECUTE startquiz(2, 4)', 
    '42501',
    'new row violates row-level security policy for table "quiz_submission"',
    'students should not be able to create quiz submissions if it is not for them'
);

SELECT lives_ok(
    'EXECUTE startquiz(2, 3)', 
    'students should be able to create quiz submissions if it is for themselves, not draft, after open, and before closed'
);

SELECT set_eq(
    'SELECT quiz_id FROM api.quiz_submissions ORDER BY (quiz_id)',
    ARRAY[2],
    'students shoud only be able to see their newly created quiz submissions (user 3)'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
SELECT throws_ok(
    'EXECUTE startquiz(2, 3)', 
    '23505',
    'duplicate key value violates unique constraint "quiz_submission_pkey"',
    'only one quiz is allowed per user per quiz'
);


select * from finish();
rollback;
