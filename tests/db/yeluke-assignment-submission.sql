begin;
select plan(30);

-- We test exceptions elsewhere.
DELETE FROM api.assignment_grade_exceptions;

SELECT view_owner_is(
    'api', 'assignment_submissions', 'api',
    'api.assignment_submissions view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignment_submissions', 'student', ARRAY['SELECT', 'INSERT'],
    'student should only be granted SELECT, INSERT on view "api.assignment_submissions"'
);

SELECT table_privs_are(
    'api', 'assignment_submissions', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.assignment_submissions"'
);

SELECT table_privs_are(
    'data', 'assignment_submission', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.assignment_submission"'
);

SELECT is(
    (
        SELECT count(*)::int
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment'
        AND a.attname = 'is_team'
        AND a.attnotnull
    ),
    1,
    'assignment.is_team should be NOT NULL'
);

SELECT is(
    (
        SELECT count(*)::int
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_submission'
        AND a.attname = 'is_team'
        AND a.attnotnull
    ),
    1,
    'assignment_submission.is_team should be NOT NULL'
);

SELECT has_table(
    'data', 'assignment_submission_participant',
    'assignment_submission_participant table should snapshot submission membership'
);

SELECT col_is_pk(
    'data', 'assignment_submission_participant', ARRAY['assignment_submission_id', 'user_id'],
    'assignment_submission_participant should be keyed by submission and user'
);

SELECT set_eq(
    'SELECT user_id FROM data.assignment_submission_participant WHERE assignment_submission_id = 4 ORDER BY user_id',
    ARRAY[1, 3],
    'team submission participants should be snapshotted at submission time'
);

SELECT throws_like(
    $$
        INSERT INTO data.assignment_submission (assignment_slug, user_id, submitter_user_id)
        VALUES ('missing-assignment', 4, 4)
    $$,
    '%null value in column "is_team"%',
    'assignment submissions for unknown assignments cannot bypass ownership constraints with NULL is_team'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    'SELECT id FROM api.assignment_submissions ORDER BY (id)',
    ARRAY[1, 2, 3, 4],
    'faculty should be able to see all assignment submissions XXX'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT id FROM api.assignment_submissions ORDER BY (id)',
    ARRAY[1, 4],
    'students shoud only be able to see assignment submissions that are their own or team submissions for their team (user 1)'
);

set request.jwt.claim.user_id = '2';

SELECT set_eq(
    'SELECT id FROM api.assignment_submissions ORDER BY (id)',
    ARRAY[2],
    'students shoud only be able to see assignment submissions that are their own or team submissions for their team (user 2)'
);

PREPARE doinsert AS INSERT INTO api.assignment_submissions (id, assignment_slug, is_team, user_id, team_nickname, submitter_user_id) VALUES($1, $2, $3, $4, $5, $6);
PREPARE doinsert_noid AS INSERT INTO api.assignment_submissions (assignment_slug, is_team, user_id, team_nickname, submitter_user_id) VALUES($1, $2, $3, $4, $5);
PREPARE doinsert_no_submitted_by AS INSERT INTO api.assignment_submissions (assignment_slug, is_team, user_id, team_nickname) VALUES($1, $2, $3, $4);
PREPARE doinsert_noteam AS INSERT INTO api.assignment_submissions (assignment_slug, user_id, submitter_user_id) VALUES($1, $2, $3);


SELECT throws_like(
    'EXECUTE doinsert(6, ''team-selection'', FALSE, 4, NULL, 4)', 
    '%violates row-level security policy%',
    'students should not be able to create an assignment submission for a different user'
);

-- TODO
--  fk enforced
-- no dups
-- exercise the constraints
set request.jwt.claim.user_id = '4';

SELECT throws_like(
    'EXECUTE doinsert(6, ''js-koans'', FALSE, 4, NULL, 4)', 
    '%violates row-level security policy%',
    'students should not be able to create assignment submissions if assignment is draft'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.assignments SET closed_at = current_timestamp - '1 hour'::INTERVAL WHERE slug='team-selection';

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';

SELECT throws_like(
    'EXECUTE doinsert(6, ''team-selection'', FALSE, 4, NULL, 4)', 
    '%violates row-level security policy%',
    'students should not be able to create assignment submissions if assignment is past closed_at'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.assignments SET closed_at = current_timestamp + '1 hour'::INTERVAL WHERE slug='team-selection';

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';


SELECT lives_ok(
    'EXECUTE doinsert_noid(''team-selection'', FALSE, 4, NULL, 4)', 
    'students should be able to insert individual assignment submission'
);

SELECT set_eq(
    'SELECT COUNT(*) FROM api.assignment_submissions WHERE user_id=4 AND assignment_slug=''team-selection''',
    ARRAY[1],
    'students shoud only be able to see their newly created individual assignment submission'
);

SELECT results_eq(
    $$
        INSERT INTO api.assignment_submissions (assignment_slug)
        VALUES ('exam-1')
        RETURNING is_team, user_id, team_nickname
    $$,
    $$VALUES (FALSE, 4, NULL::text)$$,
    'minimal assignment submission insert should fill individual assignment ownership'
);

SELECT throws_like(
    'EXECUTE doinsert_noid(''team-selection'', FALSE, 4, NULL, 4)',
    '%duplicate key%',
    'students should only get one submission per assignment'
);



SELECT throws_like(
    'EXECUTE doinsert_noid(''project-update-1'', FALSE, 2, NULL, 2)',
    '%violates row-level security policy%',
    'students should NOT be able to insert team assignment submission if they are not on a team'
);


set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '2';

SELECT results_eq(
    $$
        INSERT INTO api.assignment_submissions (assignment_slug)
        VALUES ('project-update-1')
        RETURNING is_team, user_id, team_nickname
    $$,
    $$VALUES (TRUE, NULL::int, 'hazy-mountain'::text)$$,
    'minimal assignment submission insert should fill team assignment ownership'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
DELETE FROM api.assignment_submissions WHERE team_nickname='hazy-mountain' AND assignment_slug='project-update-1';

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '2';

SELECT lives_ok(
    'EXECUTE doinsert_noid( ''project-update-1'', TRUE, NULL, ''hazy-mountain'', 2)',
    'students should be able to insert team assignment submissions on behalf of their team'
);

SELECT throws_like(
    'EXECUTE doinsert_noid( ''project-update-1'', TRUE, NULL, ''hazy-mountain'', 2)',
    '%duplicate key%',
    'teams should only get one submission per assignment'
);


set local role faculty;
set request.jwt.claim.role = 'faculty';
DELETE FROM api.assignment_submissions WHERE team_nickname='hazy-mountain' AND assignment_slug='project-update-1';

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '2';

SELECT lives_ok(
    'EXECUTE doinsert_noteam( ''project-update-1'', NULL, 2)',
    'the team_nickname is added automatically when it is NULL on insert'
);
-- Can't submit team submission with user_id, individual w/o it

RESET ROLE;
UPDATE data.user SET team_nickname = 'damp-pond' WHERE id = 1;
UPDATE data.user SET team_nickname = 'bright-fog' WHERE id = 2;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT id FROM api.assignment_submissions ORDER BY (id)',
    ARRAY[1, 4],
    'students should keep access to team submissions they participated in after leaving the team'
);

set request.jwt.claim.user_id = '2';

SELECT set_eq(
    'SELECT id FROM api.assignment_submissions WHERE id = 4 ORDER BY (id)',
    ARRAY[]::int[],
    'students should not gain access to historical team submissions after joining the team later'
);

RESET ROLE;
INSERT INTO data."user" (id, email, netid, nickname, role, team_nickname)
VALUES (6, 'student6@yale.edu', 'stu6', 'quiet-river', 'student', 'bright-fog');
INSERT INTO data.assignment (slug, is_team, points_possible, title, body, closed_at, is_draft)
VALUES ('project-update-2', TRUE, 75, 'Second Project Update', 'body', current_timestamp + '1 day'::interval, FALSE);
UPDATE data.user SET team_nickname = 'bright-fog' WHERE id = 1;
UPDATE data.user SET team_nickname = 'hazy-mountain' WHERE id = 2;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

INSERT INTO api.assignment_submissions (assignment_slug)
VALUES ('project-update-2');

RESET ROLE;
UPDATE data.user SET team_nickname = 'damp-pond' WHERE id = 1;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '6';

SELECT set_eq(
    'SELECT assignment_slug FROM api.assignment_submissions WHERE assignment_slug = ''project-update-2''',
    ARRAY['project-update-2'],
    'non-submitter student participants should keep access after the submitter leaves the team'
);

RESET ROLE;
UPDATE data.assignment_submission
SET team_nickname = 'damp-pond'
WHERE assignment_slug = 'project-update-2';

SELECT set_eq(
    $$
        SELECT user_id
        FROM data.assignment_submission_participant
        WHERE assignment_submission_id = (
            SELECT id
            FROM data.assignment_submission
            WHERE assignment_slug = 'project-update-2'
        )
        ORDER BY user_id
    $$,
    ARRAY[1, 3, 6],
    'assignment submission participants should not be resnapshotted by submission key updates'
);

UPDATE data.user SET team_nickname = 'bright-fog' WHERE id = 2;

SELECT set_eq(
    $$
        SELECT user_id
        FROM data.assignment_submission_participant
        WHERE assignment_submission_id = (
            SELECT id
            FROM data.assignment_submission
            WHERE assignment_slug = 'project-update-2'
        )
        ORDER BY user_id
    $$,
    ARRAY[1, 3, 6],
    'late team joiners should not be added to existing participant snapshots'
);


select * from finish();
rollback;
