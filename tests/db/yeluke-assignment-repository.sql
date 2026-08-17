-- data.assignment_repository: the record of which forge repository belongs to
-- which student or team for which assignment (#312).
--
-- Sample data this file leans on: users 1 (abc123, student, team bright-fog),
-- 2 (bde456, student, team hazy-mountain), 3 (klj39, faculty), 4 (jlb325, ta,
-- no team); assignments exam-1 and team-selection (individual) and
-- project-update-1 (team).

SELECT plan(30);

-- ---------------------------------------------------------------------------
-- Shape and privileges
-- ---------------------------------------------------------------------------

SELECT has_table(
    'data', 'assignment_repository',
    'assignment_repository table should record provisioned repositories'
);

SELECT view_owner_is(
    'api', 'assignment_repositories', 'api',
    'api.assignment_repositories view should be owned by the api role, or its RLS policy never applies'
);

SELECT table_privs_are(
    'api', 'assignment_repositories', 'faculty',
    ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should have CRUD on view "api.assignment_repositories"'
);

SELECT table_privs_are(
    'api', 'assignment_repositories', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.assignment_repositories"'
);

SELECT table_privs_are(
    'api', 'assignment_repositories', 'ta', ARRAY['SELECT'],
    'ta should only be granted SELECT on view "api.assignment_repositories"'
);

SELECT table_privs_are(
    'data', 'assignment_repository', 'faculty', ARRAY[]::text[],
    'faculty should be granted nothing on "data.assignment_repository"'
);

SELECT table_privs_are(
    'data', 'assignment_repository', 'student', ARRAY[]::text[],
    'student should be granted nothing on "data.assignment_repository"'
);

-- ---------------------------------------------------------------------------
-- Exactly one of user_id / team_nickname, agreeing with the assignment's kind
-- ---------------------------------------------------------------------------
-- Written against the base table as the test superuser, because these are
-- constraints rather than policy: they hold whoever is asking.

SELECT lives_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name, provider_user_id)
        VALUES ('exam-1', FALSE, 1, 100000001, 'mgt-656/exam-1-abc123', 900000001)
    $$,
    'an individual repository names a user and no team'
);

SELECT lives_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, team_nickname, provider_repo_id, provider_full_name)
        VALUES ('project-update-1', TRUE, 'bright-fog', 100000002, 'mgt-656/project-update-1-bright-fog')
    $$,
    'a team repository names a team and no user'
);

SELECT throws_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, user_id, team_nickname, provider_repo_id, provider_full_name)
        VALUES ('exam-1', FALSE, 2, 'hazy-mountain', 100000003, 'mgt-656/both')
    $$,
    '23514',
    NULL,
    'a repository cannot belong to a user and a team at once'
);

SELECT throws_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, provider_repo_id, provider_full_name)
        VALUES ('exam-1', FALSE, 100000004, 'mgt-656/nobody')
    $$,
    '23514',
    NULL,
    'an individual repository cannot belong to nobody'
);

SELECT throws_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
        VALUES ('project-update-1', TRUE, 2, 100000005, 'mgt-656/team-owned-by-a-user')
    $$,
    '23514',
    NULL,
    'a team repository cannot belong to a user'
);

-- The foreign key to (assignment.slug, assignment.is_team) is what makes a team
-- repository on an individual assignment unrepresentable. Without it the row
-- above would be internally consistent and still wrong.
SELECT throws_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, team_nickname, provider_repo_id, provider_full_name)
        VALUES ('exam-1', TRUE, 'bright-fog', 100000006, 'mgt-656/team-repo-on-solo-assignment')
    $$,
    '23503',
    NULL,
    'a team repository cannot be provisioned for an individual assignment'
);

-- ---------------------------------------------------------------------------
-- Uniqueness
-- ---------------------------------------------------------------------------

SELECT throws_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
        VALUES ('exam-1', FALSE, 1, 100000007, 'mgt-656/exam-1-abc123-again')
    $$,
    '23505',
    NULL,
    'a student cannot have two repositories for one assignment'
);

SELECT lives_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
        VALUES ('team-selection', FALSE, 1, 100000008, 'mgt-656/team-selection-abc123')
    $$,
    'the same student can have a repository for a different assignment'
);

SELECT throws_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, team_nickname, provider_repo_id, provider_full_name)
        VALUES ('project-update-1', TRUE, 'bright-fog', 100000009, 'mgt-656/project-update-1-bright-fog-again')
    $$,
    '23505',
    NULL,
    'a team cannot have two repositories for one assignment'
);

-- Identity, from the other direction: one repository is the repository of at
-- most one student. Reusing a repo id across students is how a provisioning
-- retry silently reattaches one student's work to another.
SELECT throws_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
        VALUES ('exam-1', FALSE, 2, 100000001, 'mgt-656/exam-1-bde456')
    $$,
    '23505',
    NULL,
    'one forge repository cannot be handed to two students'
);

-- Repo ids are only unique within a forge, which is why `provider` is part of
-- that key and not part of the per-student one.
SELECT lives_ok(
    $$
        INSERT INTO data.assignment_repository
            (assignment_slug, is_team, user_id, provider, provider_repo_id, provider_full_name)
        VALUES ('exam-1', FALSE, 2, 'gitea', 100000001, 'mgt-656/exam-1-bde456')
    $$,
    'the same repository id on a different forge is a different repository'
);

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
-- A known board: two individual exam-1 repositories owned by users 1 and 2, and
-- two project-update-1 team repositories, one for each student's team.

DELETE FROM data.assignment_repository;

INSERT INTO data.assignment_repository
    (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
VALUES
    ('exam-1', FALSE, 1, 200000001, 'mgt-656/exam-1-abc123'),
    ('exam-1', FALSE, 2, 200000002, 'mgt-656/exam-1-bde456');

INSERT INTO data.assignment_repository
    (assignment_slug, is_team, team_nickname, provider_repo_id, provider_full_name)
VALUES
    ('project-update-1', TRUE, 'bright-fog', 200000003, 'mgt-656/project-update-1-bright-fog'),
    ('project-update-1', TRUE, 'hazy-mountain', 200000004, 'mgt-656/project-update-1-hazy-mountain');

SET LOCAL ROLE faculty;
SET request.jwt.claim.role = 'faculty';
SET request.jwt.claim.user_id = '3';

SELECT set_eq(
    'SELECT provider_full_name FROM api.assignment_repositories',
    ARRAY[
        'mgt-656/exam-1-abc123',
        'mgt-656/exam-1-bde456',
        'mgt-656/project-update-1-bright-fog',
        'mgt-656/project-update-1-hazy-mountain'
    ],
    'faculty should see every provisioned repository'
);

SELECT lives_ok(
    $$
        INSERT INTO api.assignment_repositories
            (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
        VALUES ('team-selection', FALSE, 1, 200000005, 'mgt-656/team-selection-abc123')
    $$,
    'faculty should be able to provision a repository through the view'
);

-- Names are display and expected to go stale; a rename must be an update of
-- this row rather than a new identity.
SELECT lives_ok(
    $$
        UPDATE api.assignment_repositories
        SET provider_full_name = 'mgt-656/exam-1-alice'
        WHERE provider_repo_id = 200000001
    $$,
    'faculty should be able to record a repository rename'
);

SET LOCAL ROLE student;
SET request.jwt.claim.role = 'student';
SET request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT provider_full_name FROM api.assignment_repositories',
    ARRAY[
        'mgt-656/exam-1-alice',
        'mgt-656/project-update-1-bright-fog',
        'mgt-656/team-selection-abc123'
    ],
    'a student should see their own repositories and their current team''s, and nothing else'
);

SELECT is_empty(
    $$
        SELECT provider_full_name FROM api.assignment_repositories
        WHERE provider_repo_id IN (200000002, 200000004)
    $$,
    'a student should not see another student''s repository or another team''s'
);

SELECT throws_ok(
    $$
        INSERT INTO api.assignment_repositories
            (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
        VALUES ('js-koans', FALSE, 1, 200000006, 'mgt-656/js-koans-abc123')
    $$,
    '42501',
    NULL,
    'a student cannot provision a repository for themselves'
);

-- The one that matters most: a student who could repoint an assignment at
-- another repository could hand in different work after the deadline.
SELECT throws_ok(
    $$
        UPDATE api.assignment_repositories
        SET provider_repo_id = 200000009
        WHERE provider_repo_id = 200000001
    $$,
    '42501',
    NULL,
    'a student cannot repoint their own assignment at another repository'
);

SELECT throws_ok(
    $$DELETE FROM api.assignment_repositories WHERE provider_repo_id = 200000001$$,
    '42501',
    NULL,
    'a student cannot delete their own repository record'
);

SET request.jwt.claim.user_id = '2';

SELECT set_eq(
    'SELECT provider_full_name FROM api.assignment_repositories',
    ARRAY[
        'mgt-656/exam-1-bde456',
        'mgt-656/project-update-1-hazy-mountain'
    ],
    'the other student sees their own repositories, and the first student''s are not among them'
);

-- A TA is on the student side of the policy, not the faculty side, so a TA with
-- no repositories and no team sees nothing rather than everything.
SET LOCAL ROLE ta;
SET request.jwt.claim.role = 'ta';
SET request.jwt.claim.user_id = '4';

SELECT is_empty(
    'SELECT provider_full_name FROM api.assignment_repositories',
    'a ta with no repositories of their own should see none'
);

RESET ROLE;

-- Team membership is live, not snapshotted: a repository is a grant on the
-- forge, and a student moved off a team loses it there at the same moment.
-- data.assignment_submission_participant deliberately does the opposite,
-- because submitted work is history and must not be rewritten by a later
-- roster change.
UPDATE data."user" SET team_nickname = 'hazy-mountain' WHERE id = 1;

SET LOCAL ROLE student;
SET request.jwt.claim.role = 'student';
SET request.jwt.claim.user_id = '1';

SELECT is_empty(
    $$
        SELECT provider_full_name FROM api.assignment_repositories
        WHERE provider_repo_id = 200000003
    $$,
    'a student moved off a team stops seeing that team''s repository'
);

SELECT isnt_empty(
    $$
        SELECT provider_full_name FROM api.assignment_repositories
        WHERE provider_repo_id = 200000004
    $$,
    'and starts seeing the repository of the team they joined'
);

RESET ROLE;

SELECT * FROM finish();
