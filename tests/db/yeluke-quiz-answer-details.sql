begin;
select plan(2);


SELECT table_privs_are(
    'api', 'quiz_answer_details', 'student', ARRAY[]::TEXT[],
    'student should have no privileges on the quiz_answer_details view'
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
