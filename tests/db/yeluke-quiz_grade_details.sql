begin;
select plan(6);

SELECT view_owner_is(
    'api', 'quiz_grade_details', 'api',
    'api.quiz_grade_details view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'quiz_grade_details', 'student', ARRAY[]::TEXT[],
    'student should only be granted NOTHING on view "api.quiz_grade_details"'
);

SELECT table_privs_are(
    'api', 'quiz_grade_details', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on view "api.quiz_grade_details"'
);

SELECT table_privs_are(
    'api', 'quiz_grade_details', 'ta', ARRAY['SELECT'],
    'TAs should only be granted SELECT on view "api.quiz_grade_details"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select quiz_id from api.quiz_grade_details',
    '%permission denied%',
    'anonymous users should not be able to use the api.quiz_grade_details view'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    $$select user_id, quiz_id from api.quiz_answer_details$$,
    $$select "users".id user_id, quizzes.id quiz_id from api.users cross join api.quizzes$$,
    'every possible user/quiz combo should be represented in quiz_answer_details'
);

select * from finish();
rollback;
