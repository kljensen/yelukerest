begin;
select plan(17);

SELECT view_owner_is(
    'api', 'quiz_answers', 'api',
    'api.quiz_answers view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'quiz_answers', 'student', ARRAY['SELECT', 'INSERT', 'DELETE'],
    'student should only be granted SELECT, INSERT, DELETE on view "api.quiz_answers"'
);

SELECT table_privs_are(
    'api', 'quiz_answers', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.quiz_answers"'
);

SELECT table_privs_are(
    'data', 'quiz', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz_answer"'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

-- Make all the quizzes look like they were just started
UPDATE api.quizzes SET created_at=current_timestamp, updated_at=current_timestamp;

-- Delete exceptions. We test those separately.
DELETE FROM api.quiz_grade_exceptions;


SELECT results_eq(
    'SELECT DISTINCT(user_id) FROM api.quiz_answers',
    ARRAY[1, 2],
    'faculty should be able to see all quiz answers'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT DISTINCT(user_id) FROM api.quiz_answers',
    ARRAY[1],
    'students shoud only be able to see their own quiz answers (user 1)'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

-- Users #3 & #4 is going to start quiz #2, which is still open.
INSERT INTO api.quiz_submissions (quiz_id, user_id)
    VALUES (2, 3), (2, 4);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '3';

PREPARE insertanswer AS INSERT INTO api.quiz_answers (quiz_id,user_id,quiz_question_option_id) VALUES($1, $2, $3);
PREPARE deleteanswer AS DELETE FROM api.quiz_answers WHERE user_id = $1 and quiz_question_option_id = $2;

SELECT throws_ilike(
    'EXECUTE insertanswer(2, 3, 1)', 
    '%foreign key constraint%',
    'students cannot point a quiz answer at an option not tied to this quiz'
);

SELECT throws_ilike(
    'EXECUTE insertanswer(2, 4, 1)', 
    '%row-level security%',
    'students cannot submit a quiz answer for another user'
);

SELECT throws_ilike(
    'EXECUTE insertanswer(1, 3, 1)', 
    '%foreign key constraint%',
    'students cannot submit a quiz answer for a quiz they have not started'
);

SELECT lives_ok(
    'EXECUTE insertanswer(2, 3, 5)', 
    'students can answer questions once they have a quiz submission'
);

SELECT lives_ok(
    'EXECUTE deleteanswer(3, 5)', 
    'students can delete answers to questions once they have a quiz submission'
);

SELECT lives_ok(
    'INSERT INTO api.quiz_answers (quiz_question_option_id) VALUES (5)', 
    'the quiz_id and user_id are automatically filled by triggers'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
SELECT throws_ilike(
    $$
        SELECT api.save_quiz(1, ARRAY[1,2])
    $$,
    '%row-level security%',
    'the save_quiz function adheres to RLS (quiz 1 is closed)'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.quizzes SET closed_at = current_timestamp + '10 minutes'::INTERVAL WHERE id=1;
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
SELECT results_eq(
    $$
        SELECT quiz_question_option_id FROM api.save_quiz(1, ARRAY[1,2])
    $$,
    ARRAY[1,2],
    'the save_quiz function allows students to overwrite all quiz answers in bulk'
);

-- Make this student's quiz submission look like it was started 1000 years ago
set local role faculty;
set request.jwt.claim.role = 'faculty';
DELETE FROM api.quiz_answers WHERE user_id=3 AND quiz_question_option_id=5;
UPDATE api.quiz_submissions SET created_at=created_at - '1000 years'::INTERVAL WHERE quiz_id=2 AND user_id=3;
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '3';


SELECT throws_like(
    'EXECUTE insertanswer(2, 3, 5)', 
    '%row-level security%',
    'students cannot submit quiz answers after the quiz duration passes'
);


set local role faculty;
set request.jwt.claim.role = 'faculty';
EXECUTE insertanswer(2, 4, 5);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '3';

DELETE FROM api.quiz_answers;
set request.jwt.claim.user_id = '4';

SELECT results_eq(
    'SELECT (quiz_question_option_id) FROM api.quiz_answers',
    ARRAY[5],
    'students should not be able to delete other users answers'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
DELETE FROM api.quiz_answers WHERE quiz_question_option_id = 5;
DELETE FROM api.quiz_question_options WHERE id = 5;

SELECT results_eq(
    'SELECT (quiz_question_option_id) FROM api.quiz_answers WHERE quiz_question_option_id=5',
    ARRAY[]::integer[],
    'deleting a quiz question option should cascade delete answers pointing to it'
);

-- TODO: parameterize these so I'm not relying on so much knowledge of the sample data
EXECUTE insertanswer(2, 4, 6);


select * from finish();
rollback;
