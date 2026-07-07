begin;
select plan(12);

SELECT view_owner_is(
    'api', 'assignment_grade_distributions', 'superuser',
    'api.assignment_grade_distributions view should be owned by the superuser role'
);

SELECT table_privs_are(
    'api', 'assignment_grade_distributions', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.assignment_grade_distributions"'
);

SELECT table_privs_are(
    'api', 'assignment_grade_distributions', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on view "api.assignment_grade_distributions"'
);

SELECT table_privs_are(
    'api', 'assignment_grade_distributions', 'ta', ARRAY['SELECT'],
    'TAs should only be granted SELECT on view "api.assignment_grade_distributions"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select assignment_slug from api.assignment_grade_distributions',
    '%permission denied%',
    'anonymous users should not be able to use the api.assignment_grade_distributions view'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';


SELECT set_eq(
    'SELECT assignment_slug FROM api.assignment_grade_distributions',
    ARRAY[]::text[],
    'students should not see assignment grade stats for cohorts smaller than three'
);

SELECT throws_like(
    'UPDATE api.assignment_grade_distributions SET assignment_slug=''team-selection'' WHERE assignment_slug = ''team-selection''',
    '%cannot update view%',
    'students should NOT be able to alter assignment grade stats'
);

RESET ROLE;
INSERT INTO data."user" (id, email, netid, nickname, role)
VALUES (6, 'student6@yale.edu', 'stu6', 'quiet-river', 'student');

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT results_eq(
    $$
        SELECT assignment_slug, count::int, average, grades
        FROM api.assignment_grade_distributions
        WHERE assignment_slug = 'team-selection'
    $$,
    $$VALUES ('team-selection', 3, 30::double precision, ARRAY[0::real, 40::real, 50::real])$$,
    'assignment grade distributions should count missing individual submissions as zero'
);

SELECT results_eq(
    $$
        SELECT assignment_slug
        FROM api.assignment_grade_distributions
        WHERE assignment_slug = 'js-koans'
    $$,
    $$VALUES ('never-returned'::text) LIMIT 0$$,
    'assignment grade distributions should not reveal draft assignments as zero-score cohorts'
);

RESET ROLE;
INSERT INTO data.assignment_submission (id, assignment_slug, is_team, user_id, submitter_user_id)
VALUES (5, 'team-selection', false, 6, 6);
INSERT INTO data.assignment_grade (assignment_submission_id, assignment_slug, points)
VALUES (5, 'team-selection', 30);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT results_eq(
    $$
        SELECT assignment_slug, count::int, grades
        FROM api.assignment_grade_distributions
        WHERE assignment_slug = 'team-selection'
    $$,
    $$VALUES ('team-selection', 3, ARRAY[30::real, 40::real, 50::real])$$,
    'assignment grade distributions should show cohorts with at least three student grades'
);

RESET ROLE;
UPDATE data.user SET team_nickname = 'bright-fog' WHERE id = 2;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT results_eq(
    $$
        SELECT assignment_slug
        FROM api.assignment_grade_distributions
        WHERE assignment_slug = 'project-update-1'
    $$,
    $$VALUES ('never-returned'::text) LIMIT 0$$,
    'assignment grade distributions should use submission-time team participants before applying cohort suppression'
);


set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT throws_like(
    'UPDATE api.assignment_grade_distributions SET assignment_slug=''team-selection'' WHERE assignment_slug = ''team-selection''',
    '%cannot update view%',
    'faculty should NOT be able to alter assignment grade stats'
);

select * from finish();
rollback;
