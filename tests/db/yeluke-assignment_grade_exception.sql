SELECT plan(16)
; SELECT view_owner_is('api', 'assignment_grade_exceptions', 'api', 'api.assignment_grade_exceptions view should be owned by the api role')
; SELECT table_privs_are('api', 'assignment_grade_exceptions', 'student', ARRAY['SELECT'], 'student should only be granted SELECT on view "api.assignment_grade_exceptions"')
; SELECT table_privs_are('api', 'assignment_grade_exceptions', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'], 'faculty should only be granted select, insert, update, delete on view "api.assignment_grade_exceptions"')
; SELECT table_privs_are('data', 'assignment_grade_exception', 'faculty', ARRAY[]::text[], 'faculty should only be granted nothing on "data.assignment_grade_exception"')
; SELECT col_not_null('data', 'assignment_grade_exception', 'assignment_slug', 'assignment grade exceptions must be linked to an assignment')
; SELECT throws_like('
        INSERT INTO data.assignment_grade_exception (assignment_slug, is_team, user_id, closed_at)
        VALUES (NULL, FALSE, 5, current_timestamp + ''1 hour''::INTERVAL)
    ', '%null value in column "assignment_slug"%', 'assignment grade exceptions should reject NULL assignment slugs')
; GRANT usage ON SCHEMA api, data TO api
; SET LOCAL role TO api
; SET "request.jwt.claim.role" TO app
; SET "request.jwt.claim.app_name" TO authapp
; SET "request.jwt.claim.user_id" TO "2"
; SELECT set_eq('SELECT COUNT(*)::int FROM data.assignment_grade_exception', ARRAY[0], 'non-student api request contexts should not see team assignment_grade_exceptions')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "4"
; SELECT set_eq('SELECT COUNT(*) FROM api.assignment_grade_exceptions', ARRAY[0], 'students shoud not be able to see assignment_grade_exceptions for other students')
; SET "request.jwt.claim.user_id" TO "5"
; SELECT set_eq('SELECT COUNT(*) FROM api.assignment_grade_exceptions', ARRAY[1], 'students shoud be able to see assignment_grade_exceptions of their own')
; SET "request.jwt.claim.user_id" TO "2"
; SELECT set_eq('SELECT COUNT(*) FROM api.assignment_grade_exceptions', ARRAY[1], 'students shoud be able to see assignment_grade_exceptions for their team')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; DELETE FROM api.assignment_grades
; DELETE FROM api.assignment_field_submissions
; DELETE FROM api.assignment_submissions
; UPDATE api.assignments
SET closed_at = current_timestamp - '1 hour'::interval
; PREPARE insert_submission AS
    INSERT INTO api.assignment_submissions (id, assignment_slug, is_team, user_id, team_nickname, submitter_user_id)
    VALUES ($1, $2, $3, $4, $5, $6)
; PREPARE insert_field_submission AS
    INSERT INTO api.assignment_field_submissions (assignment_submission_id, assignment_field_slug, body)
    VALUES ($1, $2, 'foo')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "5"
; SELECT lives_ok('EXECUTE insert_submission(600, ''team-selection'', FALSE, 5, NULL, 5)', 'students should be able to create assignment submissions after assignment closed_at if they have an unexpired exception')
; SELECT lives_ok('EXECUTE insert_field_submission(600, ''secret'')', 'students should be able to create assignment field submissions after assignment closed_at if they have an unexpired exception')
; SELECT throws_like('EXECUTE insert_submission(700, ''js-koans'', FALSE, 5, NULL, 5)', '%violates row-level security policy%', 'students should NOT be able to create assignment submissions for closed assignments for which they have no exception')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; UPDATE api.assignment_grade_exceptions
SET closed_at = current_timestamp - '1 hour'::interval
WHERE user_id = 5
; DELETE FROM api.assignment_field_submissions
WHERE assignment_submission_id = 600
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "5"
; SELECT throws_like('EXECUTE insert_field_submission(600, ''secret'')', '%violates row-level security policy%', 'students should NOT be able to create assignment field submissions after assignment closed_at their exception is expired')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; DELETE FROM api.assignment_submissions
WHERE id = 600
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "5"
; SELECT throws_like('EXECUTE insert_submission(600, ''team-selection'', FALSE, 5, NULL, 5)', '%violates row-level security policy%', 'students should NOT be able to create assignment submissions after assignment closed_at their exception is expired')
; SELECT throws_like('
        UPDATE api.assignment_grade_exceptions SET closed_at = current_timestamp + ''1 hour''::INTERVAL
    ', '%permission denied%', 'students should NOT be able to update assignment_grade_exceptions')
; SELECT *
FROM finish()

-- TODO, test team submission!!!
