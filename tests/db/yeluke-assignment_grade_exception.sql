begin;
select plan(11);

SELECT view_owner_is(
    'api', 'assignment_grade_exceptions', 'api',
    'api.assignment_grade_exceptions view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignment_grade_exceptions', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.assignment_grade_exceptions"'
);

SELECT table_privs_are(
    'api', 'assignment_grade_exceptions', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.assignment_grade_exceptions"'
);

SELECT table_privs_are(
    'data', 'assignment_grade_exception', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.assignment_grade_exception"'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.assignment_grade_exceptions',
    ARRAY[0],
    'students shoud not be able to see assignment_grade_exceptions for other students'
);

set request.jwt.claim.user_id = '5';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.assignment_grade_exceptions',
    ARRAY[1],
    'students shoud be able to see assignment_grade_exceptions of their own'
);

set request.jwt.claim.user_id = '2';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.assignment_grade_exceptions',
    ARRAY[1],
    'students shoud be able to see assignment_grade_exceptions for their team'
);


set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.assignments SET closed_at = current_timestamp - '1 hour'::INTERVAL WHERE slug='team-selection';
PREPARE insert_submission AS INSERT INTO api.assignment_submissions (id, assignment_slug, is_team, user_id, team_nickname, submitter_user_id) VALUES($1, $2, $3, $4, $5, $6);
PREPARE insert_field_submission AS INSERT INTO api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,body) VALUES($1, $2, 'foo');

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '5';
SELECT lives_ok(
    'EXECUTE insert_submission(600, ''team-selection'', FALSE, 5, NULL, 5)', 
    'students should be able to create assignment submissions after assignment closed_at if they have an unexpired exception'
);

SELECT lives_ok(
    'EXECUTE insert_field_submission(600, ''secret'')', 
    'students should be able to create assignment field submissions after assignment closed_at if they have an unexpired exception'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
DELETE FROM api.assignment_submissions WHERE id=600;
UPDATE api.assignment_grade_exceptions SET closed_at = current_timestamp - '1 hour'::INTERVAL WHERE user_id=5;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '5';
SELECT throws_like(
    'EXECUTE insert_submission(600, ''team-selection'', FALSE, 5, NULL, 5)', 
    '%violates row-level security policy%',
    'students should NOT be able to create assignment submissions after assignment closed_at their exception is expired'
);

SELECT throws_like(
    $$
        UPDATE api.assignment_grade_exceptions SET closed_at = current_timestamp + '1 hour'::INTERVAL
    $$, 
    '%permission denied%',
    'students should NOT be able to update assignment_grade_exceptions'
);

select * from finish();
rollback;
