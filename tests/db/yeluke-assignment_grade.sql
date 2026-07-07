begin;
select plan(15);

SELECT view_owner_is(
    'api', 'assignment_grades', 'api',
    'api.assignment_grades view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignment_grades', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.assignment_grades"'
);

SELECT table_privs_are(
    'api', 'assignment_grades', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.assignment_grades"'
);

SELECT table_privs_are(
    'data', 'assignment_grade', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.assignment_grade"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select * from api.assignment_grades',
    '%permission denied%',
    'anonymous users should not be able to use the api.assignment_grades view'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';


SELECT set_eq(
    'SELECT assignment_submission_id FROM api.assignment_grades',
    ARRAY[1, 4],
    'students should be able to see assignment grades for only themselves and their team'
);

SELECT throws_like(
    'UPDATE api.assignment_grades SET points=12 WHERE assignment_submission_id = 1',
    '%permission denied%',
    'students should NOT be able to alter their assignment grades'
);


set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    'SELECT assignment_submission_id FROM api.assignment_grades',
    ARRAY[1, 2, 3, 4],
    'faculty should be able to see all assignment grades'
);

SELECT lives_ok(
    'UPDATE api.assignment_grades SET points=12 WHERE assignment_submission_id = 1',
    'faculty should be able to alter assignment grades'
);

SELECT throws_like(
    'UPDATE api.assignment_grades SET points=100000 WHERE assignment_submission_id = 1',
    '%constraint%',
    'are limited to the point range of the assignment'
);

SELECT throws_like(
    'INSERT INTO api.assignment_grades (assignment_submission_id, assignment_slug, points) VALUES (10, ''team-selection'', 13)',
    '%violates foreign key%',
    'cannot have a grade for an assignment where there is no submission'
);

DELETE FROM api.assignment_grades where assignment_submission_id=4;
SELECT lives_ok(
    $$
        INSERT INTO api.assignment_grades (assignment_submission_id, points) VALUES (4,  0)
    $$,
    'assignment_slug should be automatically populated via trigger when assignment_submission_id is specified'
);

RESET ROLE;
DELETE FROM data.assignment_grade WHERE assignment_submission_id = 4;
SELECT set_eq(
    $$
        WITH inserted_rows AS (
            INSERT INTO data.assignment_grade (assignment_submission_id, points)
            VALUES (4, 0)
            RETURNING assignment_slug
        )
        SELECT assignment_slug FROM inserted_rows
    $$,
    ARRAY['project-update-1'],
    'assignment_slug should be automatically populated for direct data.assignment_grade inserts'
);

RESET ROLE;
UPDATE data.assignment_grade
SET points = 75, description = NULL
WHERE assignment_submission_id = 4;

RESET ROLE;
UPDATE data.user SET team_nickname = 'damp-pond' WHERE id = 1;
UPDATE data.user SET team_nickname = 'bright-fog' WHERE id = 2;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT assignment_submission_id FROM api.assignment_grades ORDER BY assignment_submission_id',
    ARRAY[1, 4],
    'students should keep access to team grades they participated in after leaving the team'
);

set request.jwt.claim.user_id = '2';

SELECT set_eq(
    'SELECT assignment_submission_id FROM api.assignment_grades ORDER BY assignment_submission_id',
    ARRAY[2],
    'students should not gain access to historical team grades after joining the team later'
);



select * from finish();
rollback;
