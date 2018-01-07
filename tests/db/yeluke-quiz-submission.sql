begin;
select plan(7);

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

select * from finish();
rollback;
