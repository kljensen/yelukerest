begin;
select plan(2);


SELECT table_privs_are(
    'api', 'quiz_answer_details', 'student', ARRAY[]::TEXT[],
    'student should have no privileges on the quiz_answer_details view'
);

SELECT set_eq(
    $$select user_id, quiz_id from api.quiz_answer_details$$,
    $$select "user".id user_id, quiz.id quiz_id from data.user cross join data.quiz$$,
    'every possible user/quiz combo should be represented in quiz_answer_details'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';


select * from finish();
rollback;
