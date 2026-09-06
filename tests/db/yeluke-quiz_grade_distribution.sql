SELECT plan(10)
; SELECT view_owner_is('api', 'quiz_grade_distributions', 'yelukerest_migrator', 'api.quiz_grade_distributions view should be owned by the migrator role')
; SELECT table_privs_are('api', 'quiz_grade_distributions', 'student', ARRAY['SELECT'], 'student should only be granted SELECT on view "api.quiz_grade_distributions"')
; SELECT table_privs_are('api', 'quiz_grade_distributions', 'faculty', ARRAY['SELECT'], 'faculty should only be granted SELECT on view "api.quiz_grade_distributions"')
; SELECT table_privs_are('api', 'quiz_grade_distributions', 'ta', ARRAY['SELECT'], 'TAs should only be granted SELECT on view "api.quiz_grade_distributions"')
;
-- switch to a anonymous application user
SET LOCAL role TO anonymous
; SET "request.jwt.claim.role" TO anonymous
; SELECT throws_like('select quiz_id from api.quiz_grade_distributions', '%permission denied%', 'anonymous users should not be able to use the api.quiz_grade_distributions view')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT set_eq('SELECT quiz_id FROM api.quiz_grade_distributions', ARRAY[]::int[], 'students should not see quiz grade stats for cohorts smaller than three')
; RESET role
; INSERT INTO data.quiz_submission (quiz_id, user_id)
VALUES (2, 1)
; INSERT INTO data.quiz_grade (quiz_id, user_id, points)
VALUES (2, 1, 10)
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT results_eq('
        SELECT quiz_id
        FROM api.quiz_grade_distributions
        WHERE quiz_id = 2
    ', 'VALUES (0) LIMIT 0', 'quiz grade distributions should suppress singleton cohorts')
; RESET role
; INSERT INTO data."user" (id, email, netid, nickname, role)
VALUES (6, 'student6@yale.edu', 'stu6', 'quiet-river', 'student')
; INSERT INTO data.quiz_submission (quiz_id, user_id)
VALUES (1, 6)
; INSERT INTO data.quiz_grade (quiz_id, user_id, points)
VALUES (1, 6, 6)
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT results_eq('
        SELECT quiz_id, count::int, grades
        FROM api.quiz_grade_distributions
        WHERE quiz_id = 1
    ', 'VALUES (1, 3, ARRAY[0::real, 6::real, 13::real])', 'quiz grade distributions should show cohorts with at least three student grades')
; SELECT throws_like('UPDATE api.quiz_grade_distributions SET quiz_id=2 WHERE quiz_id = 1', '%cannot update view%', 'students should NOT be able to alter quiz grade stats')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SELECT throws_like('UPDATE api.quiz_grade_distributions SET quiz_id=2 WHERE quiz_id = 1', '%cannot update view%', 'faculty should NOT be able to alter quiz grade stats')
; SELECT *
FROM finish()
