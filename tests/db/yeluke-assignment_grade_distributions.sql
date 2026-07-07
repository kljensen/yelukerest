begin;
select plan(9);

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
    ARRAY['team-selection', 'project-update-1'],
    'students should be able to see assignment grade stats'
);

SELECT throws_like(
    'UPDATE api.assignment_grade_distributions SET assignment_slug=''team-selection'' WHERE assignment_slug = ''team-selection''',
    '%cannot update view%',
    'students should NOT be able to alter assignment grade stats'
);

RESET ROLE;
UPDATE data.user SET team_nickname = 'bright-fog' WHERE id = 2;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT results_eq(
    $$
        SELECT count::int, grades
        FROM api.assignment_grade_distributions
        WHERE assignment_slug = 'project-update-1'
    $$,
    $$VALUES (1, ARRAY[75::real])$$,
    'assignment grade distributions should use submission-time team participants, not current team membership'
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
