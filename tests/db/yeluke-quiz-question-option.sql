begin;
select plan(10);

SELECT view_owner_is(
    'api', 'quiz_question_options', 'api',
    'api.quiz_question_options view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'quiz_question_options', 'student', ARRAY[]::text[],
    'student should not be granted blanket select on view "api.quiz_question_options"'
);

SELECT column_privs_are(
    'api', 'quiz_question_options', 'body', 'student', ARRAY['SELECT'],
    'students can select the body column on view "api.quiz_question_options"'
);

SELECT column_privs_are(
    'api', 'quiz_question_options', 'id', 'student', ARRAY['SELECT'],
    'students can select the id column on view "api.quiz_question_options"'
);

SELECT column_privs_are(
    'api', 'quiz_question_options', 'is_correct', 'student', ARRAY[]::text[],
    'students cannot select the is_correct column on view "api.quiz_question_options"'
);
-- SELECT column_privs_are ( :schema, :table, :column, :role, :privileges, :description );


SELECT table_privs_are(
    'api', 'quiz_question_options', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.quiz_question_options"'
);

SELECT table_privs_are(
    'data', 'quiz', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz_question"'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    'SELECT id FROM api.quiz_question_options ORDER BY (id)',
    ARRAY[1, 2, 3, 4, 5, 6],
    'faculty should be able to see all quiz questions'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT id FROM api.quiz_question_options ORDER BY (id)',
    ARRAY[1, 2, 3, 4],
    'students shoud see quiz questions if they have a quiz_submission (user 1)'
);

set request.jwt.claim.user_id = '3';

SELECT set_eq(
    'SELECT id FROM api.quiz_question_options ORDER BY (id)',
    ARRAY[]::integer[],
    'students shoud noy see quiz questions if they lack a quiz_submission (user 3)'
);

select * from finish();
rollback;
