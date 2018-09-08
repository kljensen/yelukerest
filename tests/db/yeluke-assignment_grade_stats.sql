begin;
select plan(8);

SELECT view_owner_is(
    'api', 'assignment_grade_stats', 'superuser',
    'api.assignment_grade_stats view should be owned by the superuser role'
);

SELECT table_privs_are(
    'api', 'assignment_grade_stats', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.assignment_grade_stats"'
);

SELECT table_privs_are(
    'api', 'assignment_grade_stats', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on view "api.assignment_grade_stats"'
);

SELECT table_privs_are(
    'api', 'assignment_grade_stats', 'ta', ARRAY['SELECT'],
    'TAs should only be granted SELECT on view "api.assignment_grade_stats"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select assignment_slug from api.assignment_grade_stats',
    '%permission denied%',
    'anonymous users should not be able to use the api.assignment_grade_stats view'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';


SELECT set_eq(
    'SELECT assignment_slug FROM api.assignment_grade_stats',
    ARRAY['team-selection', 'project-update-1'],
    'students should be able to see assignment grade stats'
);

SELECT throws_like(
    'UPDATE api.assignment_grade_stats SET assignment_slug=''team-selection'' WHERE assignment_slug = ''team-selection''',
    '%cannot update view%',
    'students should NOT be able to alter assignment grade stats'
);


set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT throws_like(
    'UPDATE api.assignment_grade_stats SET assignment_slug=''team-selection'' WHERE assignment_slug = ''team-selection''',
    '%cannot update view%',
    'faculty should NOT be able to alter assignment grade stats'
);

select * from finish();
rollback;
