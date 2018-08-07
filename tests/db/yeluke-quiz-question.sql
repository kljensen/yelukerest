begin;
select plan(7);

SELECT view_owner_is(
    'api', 'quiz_questions', 'api',
    'api.quiz_questions view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'quiz_questions', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.quiz_questions"'
);

SELECT table_privs_are(
    'api', 'quiz_questions', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.quiz_questions"'
);

SELECT table_privs_are(
    'data', 'quiz', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz_question"'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    'SELECT id FROM api.quiz_questions ORDER BY (id)',
    ARRAY[1, 2, 3, 4],
    'faculty should be able to see all quiz questions'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT id FROM api.quiz_questions ORDER BY (id)',
    ARRAY[1, 2],
    'students shoud only be able to see quiz questions if they have a quiz_submission (user 1)'
);

set request.jwt.claim.user_id = '3';

SELECT set_eq(
    'SELECT id FROM api.quiz_questions ORDER BY (id)',
    ARRAY[]::integer[],
    'students shoud only be able to see quiz questions if they have a quiz_submission (user 3)'
);

select * from finish();
rollback;
