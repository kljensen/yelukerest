begin;
select plan(32);

SELECT function_privs_are(
    'api', 'grant_assignment_extension',
    ARRAY['integer', 'text', 'timestamptz', 'numeric'],
    'anonymous', ARRAY[]::text[],
    'anonymous should not be able to execute api.grant_assignment_extension'
);

SELECT function_privs_are(
    'api', 'grant_assignment_extension',
    ARRAY['integer', 'text', 'timestamptz', 'numeric'],
    'student', ARRAY[]::text[],
    'students should not be able to execute api.grant_assignment_extension'
);

SELECT function_privs_are(
    'api', 'grant_assignment_extension',
    ARRAY['integer', 'text', 'timestamptz', 'numeric'],
    'ta', ARRAY[]::text[],
    'tas should not be able to execute api.grant_assignment_extension'
);

SELECT function_privs_are(
    'api', 'grant_assignment_extension',
    ARRAY['integer', 'text', 'timestamptz', 'numeric'],
    'faculty', ARRAY['EXECUTE'],
    'faculty should be able to execute api.grant_assignment_extension'
);

SELECT function_privs_are(
    'data', 'upsert_assignment_grade_exception',
    ARRAY['text', 'boolean', 'integer', 'text', 'timestamptz', 'numeric'],
    'student', ARRAY[]::text[],
    'students should not be able to write an assignment grade exception directly'
);

SELECT function_privs_are(
    'data', 'grade_exception_credit_bounds', ARRAY['text'],
    'student', ARRAY[]::text[],
    'students should not be able to read the grade exception credit bounds'
);

--
-- The whole reason this is an RPC rather than a POST to a view faculty already
-- hold CRUD on: both arbiters are partial indexes, and PostgREST's on_conflict
-- cannot carry an index predicate. If either predicate is ever dropped or
-- reshaped, the ON CONFLICT clauses inside the function stop inferring it.
--

SELECT results_eq(
    $$
        SELECT indexdef
        FROM pg_indexes
        WHERE schemaname = 'data'
        AND tablename = 'assignment_grade_exception'
        AND indexdef LIKE 'CREATE UNIQUE INDEX%'
        AND indexname <> 'assignment_grade_exception_pkey'
        ORDER BY indexdef
    $$,
    $$ VALUES
        ('CREATE UNIQUE INDEX assignment_grade_exception_unique_team ON data.assignment_grade_exception USING btree (assignment_slug, team_nickname) WHERE (is_team = true)'::text),
        ('CREATE UNIQUE INDEX assignment_grade_exception_unique_user ON data.assignment_grade_exception USING btree (assignment_slug, user_id) WHERE (is_team = false)'::text)
    $$,
    'the assignment grade exception arbiters should still be the two partial unique indexes the upsert infers'
);

-- Pins the shape data.grade_exception_credit_bounds reads. A reshaped CHECK
-- returns NULLs here, so the bounds check inside the function would quietly
-- stop rejecting anything.
SELECT results_eq(
    $$
        SELECT credit_minimum, credit_maximum
        FROM data.grade_exception_credit_bounds('assignment_grade_exception')
    $$,
    $$ VALUES (0::numeric, 1::numeric) $$,
    'the assignment fractional_credit bounds should be readable from the constraint itself'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT throws_like(
    $$ SELECT * FROM api.grant_assignment_extension(1, 'js-koans', '3020-01-01 00:00+00'::timestamptz) $$,
    '%permission denied%',
    'students should not be able to grant themselves an extension'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';

--
-- Argument guards
--

SELECT throws_like(
    $$ SELECT * FROM api.grant_assignment_extension(NULL, 'js-koans', '3020-01-01 00:00+00'::timestamptz) $$,
    '%requires a user id%',
    'grant_assignment_extension should reject a missing user id'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_assignment_extension(1, '   ', '3020-01-01 00:00+00'::timestamptz) $$,
    '%requires an assignment slug%',
    'grant_assignment_extension should reject a blank assignment slug'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_assignment_extension(1, 'js-koans', NULL) $$,
    '%an extension with no deadline is not an extension%',
    'grant_assignment_extension should reject a missing closed_at'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_assignment_extension(1, 'no-such-assignment', '3020-01-01 00:00+00'::timestamptz) $$,
    '%does not know assignment slug: no-such-assignment%',
    'grant_assignment_extension should name an unknown assignment slug'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_assignment_extension(9999, 'js-koans', '3020-01-01 00:00+00'::timestamptz) $$,
    '%does not know user id: 9999%',
    'grant_assignment_extension should name an unknown user id'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_assignment_extension(1, 'js-koans', '3020-01-01 00:00+00'::timestamptz, 1.5) $$,
    '%requires fractional_credit between 0 and 1, received 1.5%',
    'grant_assignment_extension should reject credit above the constraint ceiling'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_assignment_extension(1, 'js-koans', '3020-01-01 00:00+00'::timestamptz, -0.25) $$,
    '%requires fractional_credit between 0 and 1%',
    'grant_assignment_extension should reject credit below the constraint floor'
);

--
-- The primitive `created` is derived from. It has to come out of the write
-- itself: a prior existence check would let two concurrent grants of the same
-- new extension both report `created`, because both would complete the check
-- before either inserted.
--
-- `old` is NULL on the insert path and the pre-update row on the conflict path.
-- The older idiom, RETURNING (xmax = 0), cannot be used here: xmax is a system
-- column, an auto-updatable view has none in its rowtype, and these writes go
-- through api views so that RLS applies. Confirmed on PostgreSQL 18.4.
--

SELECT results_eq(
    $$
        INSERT INTO api.assignment_grade_exceptions
            (assignment_slug, is_team, user_id, closed_at, fractional_credit)
        VALUES ('exam-1', false, 2, '3020-01-01 00:00+00', 1)
        ON CONFLICT (assignment_slug, user_id) WHERE NOT is_team
        DO UPDATE SET
            closed_at = EXCLUDED.closed_at,
            fractional_credit = EXCLUDED.fractional_credit
        RETURNING old.id IS NULL
    $$,
    $$ VALUES (true) $$,
    'old should be null on the insert path, through the api view'
);

SELECT results_eq(
    $$
        INSERT INTO api.assignment_grade_exceptions
            (assignment_slug, is_team, user_id, closed_at, fractional_credit)
        VALUES ('exam-1', false, 2, '3020-02-01 00:00+00', 1)
        ON CONFLICT (assignment_slug, user_id) WHERE NOT is_team
        DO UPDATE SET
            closed_at = EXCLUDED.closed_at,
            fractional_credit = EXCLUDED.fractional_credit
        RETURNING old.id IS NULL
    $$,
    $$ VALUES (false) $$,
    'old should be the pre-update row on the conflict path, through the api view'
);

--
-- Individual assignments
--

SELECT results_eq(
    $$
        SELECT assignment_slug, is_team, user_id, team_nickname, closed_at,
            fractional_credit, created
        FROM api.grant_assignment_extension(
            1, 'js-koans', '3020-01-01 00:00+00'::timestamptz
        )
    $$,
    $$ VALUES (
        'js-koans'::text, false, 1, NULL::text,
        '3020-01-01 00:00+00'::timestamptz, 1::numeric, true
    ) $$,
    'a first individual grant should report what it created'
);

SELECT results_eq(
    $$
        SELECT user_id, team_nickname, closed_at, fractional_credit
        FROM api.assignment_grade_exceptions
        WHERE assignment_slug = 'js-koans'
    $$,
    $$ VALUES (1, NULL::text, '3020-01-01 00:00+00'::timestamptz, 1::numeric) $$,
    'a first individual grant should write the row it reported'
);

SELECT is(
    (
        SELECT created
        FROM api.grant_assignment_extension(
            1, 'js-koans', '3020-02-01 00:00+00'::timestamptz, 0.5
        )
    ),
    false,
    'a second grant to the same student should be reported as a move, not a creation'
);

--
-- The bug in add-assignment-grade-exception.sh. Its
-- ON CONFLICT ... DO UPDATE SET (user_id, assignment_slug, closed_at) omits
-- fractional_credit, so the deadline above moves and the credit silently does
-- not. Running that clause twice leaves fractional_credit at 1, which fails
-- this assertion.
--

SELECT results_eq(
    $$
        SELECT closed_at, fractional_credit
        FROM api.assignment_grade_exceptions
        WHERE assignment_slug = 'js-koans' AND user_id = 1
    $$,
    $$ VALUES ('3020-02-01 00:00+00'::timestamptz, 0.5::numeric) $$,
    're-granting at reduced credit should move the deadline AND the credit'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_grade_exceptions WHERE assignment_slug = 'js-koans'),
    1,
    're-granting should leave one exception rather than a second one'
);

SELECT is(
    (
        SELECT created
        FROM api.grant_assignment_extension(
            1, '  js-koans  ', '3020-03-01 00:00+00'::timestamptz
        )
    ),
    false,
    'a padded slug should resolve to the exception already there'
);

SELECT is(
    (
        SELECT fractional_credit
        FROM api.grant_assignment_extension(
            1, 'js-koans', '3020-03-01 00:00+00'::timestamptz, NULL
        )
    ),
    1::numeric,
    'a null fractional_credit should fall back to full credit'
);

--
-- Team assignments. The student names the team; an extension authorises work
-- not yet done, so the team it belongs to is the one the student is on now.
-- api.import_assignment_grades deliberately does the opposite, because a grade
-- records work already done and reaches its team through the insert-time
-- participant snapshot.
--

SELECT results_eq(
    $$
        SELECT assignment_slug, is_team, user_id, team_nickname, created
        FROM api.grant_assignment_extension(
            1, 'project-update-1', '3020-01-01 00:00+00'::timestamptz, 0.25
        )
    $$,
    $$ VALUES ('project-update-1'::text, true, NULL::int, 'bright-fog'::text, true) $$,
    'a team grant should resolve the student current team and name no user'
);

SELECT results_eq(
    $$
        SELECT is_team, user_id, team_nickname, fractional_credit
        FROM api.assignment_grade_exceptions
        WHERE assignment_slug = 'project-update-1' AND team_nickname = 'bright-fog'
    $$,
    $$ VALUES (true, NULL::int, 'bright-fog'::text, 0.25::numeric) $$,
    'a team grant should write a team row carrying no user id'
);

-- user 2 is on hazy-mountain, which the sample data already gave an exception.
SELECT results_eq(
    $$
        SELECT team_nickname, created
        FROM api.grant_assignment_extension(
            2, 'project-update-1', '3020-04-01 00:00+00'::timestamptz
        )
    $$,
    $$ VALUES ('hazy-mountain'::text, false) $$,
    'a teammate should move the team exception already there rather than add a second'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_grade_exceptions WHERE assignment_slug = 'project-update-1'),
    2,
    'two teams should hold two team exceptions between them'
);

-- user 4 is a ta on no team.
SELECT throws_like(
    $$ SELECT * FROM api.grant_assignment_extension(4, 'project-update-1', '3020-01-01 00:00+00'::timestamptz) $$,
    '%cannot extend team assignment project-update-1 for user 4, who is on no team%',
    'grant_assignment_extension should refuse a team extension for a student on no team'
);

--
-- End to end: the row this writes has to be the row the submission check reads.
-- data.assignment_submission's WITH CHECK joins the exception team_nickname to
-- the submitting student current team, so a team snapshotted from anywhere else
-- would write a row nothing could ever match.
--

DELETE FROM api.assignment_grades;
DELETE FROM api.assignment_field_submissions;
DELETE FROM api.assignment_submissions;
DELETE FROM api.assignment_grade_exceptions;
UPDATE api.assignments SET closed_at = current_timestamp - '1 hour'::INTERVAL;

SELECT * FROM api.grant_assignment_extension(
    1, 'project-update-1', current_timestamp + '1 hour'::INTERVAL, 1
);

PREPARE insert_team_submission AS
    INSERT INTO api.assignment_submissions
        (id, assignment_slug, is_team, user_id, team_nickname, submitter_user_id)
    VALUES ($1, 'project-update-1', TRUE, NULL, $2, $3);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT lives_ok(
    'EXECUTE insert_team_submission(800, ''bright-fog'', 1)',
    'a student should be able to make a team submission after closed_at on the extension their team was granted'
);

set request.jwt.claim.user_id = '2';

SELECT throws_like(
    'EXECUTE insert_team_submission(801, ''hazy-mountain'', 2)',
    '%violates row-level security policy%',
    'a student on a team with no extension should still be shut out after closed_at'
);

select * from finish();
rollback;
