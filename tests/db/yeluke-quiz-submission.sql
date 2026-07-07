begin;
select plan(13);

SELECT view_owner_is(
    'api', 'quiz_submissions', 'api',
    'api.quiz_submissions view should be owned by the api role'
);

SELECT view_owner_is(
    'api', 'quiz_submissions_info', 'api',
    'api.quiz_submissions_info view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'quiz_submissions', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.quiz_submissions"'
);

SELECT table_privs_are(
    'api', 'quiz_submissions', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.quiz_submissions"'
);
SELECT table_privs_are(
    'api', 'quiz_submissions_info', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.quiz_submissions_info"'
);

SELECT table_privs_are(
    'api', 'quiz_submissions_info', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted select on view "api.quiz_submissions_info"'
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
SELECT set_eq(
    'SELECT quiz_id FROM api.quiz_submissions_info ORDER BY (quiz_id)',
    ARRAY[1],
    'students shoud only be able to see their own quiz submissions (user 1) in the quiz_submissions_info_view'
);

SELECT results_eq(
    'SELECT is_open FROM api.quiz_submissions_info ORDER BY (quiz_id)',
    ARRAY[false],
    'paper quiz submissions are never open for online answer editing'
);

set request.jwt.claim.user_id = '3';

SELECT set_eq(
    'SELECT quiz_id FROM api.quiz_submissions ORDER BY (quiz_id)',
    ARRAY[]::integer[],
    'students shoud only be able to see their own quiz submissions (user 3)'
);

PREPARE startquiz AS INSERT INTO api.quiz_submissions (quiz_id, user_id) VALUES($1, $2);

SELECT throws_ok(
    'EXECUTE startquiz(1, 3)',
    '42501',
    'permission denied for view quiz_submissions',
    'students should not be able to create paper quiz submissions'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT throws_ok(
    'EXECUTE startquiz(1, 1)',
    '23505',
    'duplicate key value violates unique constraint "quiz_submission_pkey"',
    'only one quiz is allowed per user per quiz'
);


select * from finish();
rollback;
