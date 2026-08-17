begin;
select plan(28);

SELECT function_privs_are(
    'api', 'grant_quiz_extension',
    ARRAY['integer', 'text', 'timestamptz', 'numeric'],
    'anonymous', ARRAY[]::text[],
    'anonymous should not be able to execute api.grant_quiz_extension'
);

SELECT function_privs_are(
    'api', 'grant_quiz_extension',
    ARRAY['integer', 'text', 'timestamptz', 'numeric'],
    'student', ARRAY[]::text[],
    'students should not be able to execute api.grant_quiz_extension'
);

SELECT function_privs_are(
    'api', 'grant_quiz_extension',
    ARRAY['integer', 'text', 'timestamptz', 'numeric'],
    'ta', ARRAY[]::text[],
    'tas should not be able to execute api.grant_quiz_extension'
);

SELECT function_privs_are(
    'api', 'grant_quiz_extension',
    ARRAY['integer', 'text', 'timestamptz', 'numeric'],
    'faculty', ARRAY['EXECUTE'],
    'faculty should be able to execute api.grant_quiz_extension'
);

SELECT function_privs_are(
    'data', 'upsert_quiz_grade_exception',
    ARRAY['integer', 'integer', 'timestamptz', 'numeric'],
    'student', ARRAY[]::text[],
    'students should not be able to write a quiz grade exception directly'
);

-- Unlike its assignment twin this arbiter is a plain UNIQUE constraint, which
-- PostgREST could express. What it cannot do is resolve a meeting slug to a
-- quiz id and upsert on the result in one transaction. Pinned so the upsert
-- keeps something to infer.
SELECT results_eq(
    $$
        SELECT pg_get_constraintdef(quiz_exception_constraint.oid)
        FROM pg_constraint quiz_exception_constraint
        JOIN pg_class exception_table
            ON exception_table.oid = quiz_exception_constraint.conrelid
        JOIN pg_namespace exception_schema
            ON exception_schema.oid = exception_table.relnamespace
        WHERE exception_schema.nspname = 'data'
        AND exception_table.relname = 'quiz_grade_exception'
        AND quiz_exception_constraint.contype = 'u'
    $$,
    $$ VALUES ('UNIQUE (quiz_id, user_id)'::text) $$,
    'the quiz grade exception arbiter should still be the unique constraint the upsert infers'
);

SELECT results_eq(
    $$
        SELECT credit_minimum, credit_maximum
        FROM data.grade_exception_credit_bounds('quiz_grade_exception')
    $$,
    $$ VALUES (0::numeric, 1::numeric) $$,
    'the quiz fractional_credit bounds should be readable from the constraint itself'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT throws_like(
    $$ SELECT * FROM api.grant_quiz_extension(1, 'intro', '3020-01-01 00:00+00'::timestamptz) $$,
    '%permission denied%',
    'students should not be able to grant themselves a quiz extension'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';

--
-- Argument guards
--

SELECT throws_like(
    $$ SELECT * FROM api.grant_quiz_extension(NULL, 'intro', '3020-01-01 00:00+00'::timestamptz) $$,
    '%requires a user id%',
    'grant_quiz_extension should reject a missing user id'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_quiz_extension(1, '   ', '3020-01-01 00:00+00'::timestamptz) $$,
    '%requires a meeting slug%',
    'grant_quiz_extension should reject a blank meeting slug'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_quiz_extension(1, 'intro', NULL) $$,
    '%an extension with no deadline is not an extension%',
    'grant_quiz_extension should reject a missing closed_at'
);

-- Quizzes are keyed on their meeting, so a meeting holding no quiz and a
-- meeting that does not exist are named the same way.
SELECT throws_like(
    $$ SELECT * FROM api.grant_quiz_extension(1, 'no-such-meeting', '3020-01-01 00:00+00'::timestamptz) $$,
    '%does not know a quiz for meeting slug: no-such-meeting%',
    'grant_quiz_extension should name a meeting slug with no quiz'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_quiz_extension(9999, 'intro', '3020-01-01 00:00+00'::timestamptz) $$,
    '%does not know user id: 9999%',
    'grant_quiz_extension should name an unknown user id'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_quiz_extension(1, 'intro', '3020-01-01 00:00+00'::timestamptz, 1.5) $$,
    '%requires fractional_credit between 0 and 1, received 1.5%',
    'grant_quiz_extension should reject credit above the constraint ceiling'
);

SELECT throws_like(
    $$ SELECT * FROM api.grant_quiz_extension(1, 'intro', '3020-01-01 00:00+00'::timestamptz, -0.25) $$,
    '%requires fractional_credit between 0 and 1%',
    'grant_quiz_extension should reject credit below the constraint floor'
);

--
-- The primitive `created` is derived from, pinned here as it is for the
-- assignment RPC: it comes out of the write rather than a read taken before it,
-- so two concurrent grants of the same new extension cannot both report
-- `created`. RETURNING (xmax = 0) is unavailable through an api view.
--

SELECT results_eq(
    $$
        INSERT INTO api.quiz_grade_exceptions (quiz_id, user_id, closed_at, fractional_credit)
        VALUES (2, 2, '3020-01-01 00:00+00', 1)
        ON CONFLICT (quiz_id, user_id)
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
        INSERT INTO api.quiz_grade_exceptions (quiz_id, user_id, closed_at, fractional_credit)
        VALUES (2, 2, '3020-02-01 00:00+00', 1)
        ON CONFLICT (quiz_id, user_id)
        DO UPDATE SET
            closed_at = EXCLUDED.closed_at,
            fractional_credit = EXCLUDED.fractional_credit
        RETURNING old.id IS NULL
    $$,
    $$ VALUES (false) $$,
    'old should be the pre-update row on the conflict path, through the api view'
);

--
-- Granting
--

SELECT results_eq(
    $$
        SELECT meeting_slug, quiz_id, user_id, closed_at, fractional_credit, created
        FROM api.grant_quiz_extension(
            1, 'intro', '3020-01-01 00:00+00'::timestamptz
        )
    $$,
    $$ VALUES (
        'intro'::text, 1, 1, '3020-01-01 00:00+00'::timestamptz, 1::numeric, true
    ) $$,
    'a first quiz grant should report what it created'
);

SELECT results_eq(
    $$
        SELECT quiz_id, user_id, closed_at, fractional_credit
        FROM api.quiz_grade_exceptions
        WHERE quiz_id = 1 AND user_id = 1
    $$,
    $$ VALUES (1, 1, '3020-01-01 00:00+00'::timestamptz, 1::numeric) $$,
    'a first quiz grant should write the row it reported'
);

SELECT is(
    (
        SELECT created
        FROM api.grant_quiz_extension(
            1, 'intro', '3020-02-01 00:00+00'::timestamptz, 0.5
        )
    ),
    false,
    'a second quiz grant to the same student should be reported as a move, not a creation'
);

-- add-quiz-grade-exception.sh has the same omission its assignment sibling has:
-- ON CONFLICT ... DO UPDATE SET (user_id, quiz_id, closed_at) never carries
-- fractional_credit, so this assertion fails against that clause.
SELECT results_eq(
    $$
        SELECT closed_at, fractional_credit
        FROM api.quiz_grade_exceptions
        WHERE quiz_id = 1 AND user_id = 1
    $$,
    $$ VALUES ('3020-02-01 00:00+00'::timestamptz, 0.5::numeric) $$,
    're-granting a quiz extension at reduced credit should move the deadline AND the credit'
);

SELECT is(
    (SELECT count(*)::int FROM api.quiz_grade_exceptions WHERE quiz_id = 1 AND user_id = 1),
    1,
    're-granting should leave one quiz exception rather than a second one'
);

SELECT is(
    (
        SELECT created
        FROM api.grant_quiz_extension(
            1, '  intro  ', '3020-03-01 00:00+00'::timestamptz
        )
    ),
    false,
    'a padded meeting slug should resolve to the exception already there'
);

SELECT is(
    (
        SELECT fractional_credit
        FROM api.grant_quiz_extension(
            1, 'intro', '3020-03-01 00:00+00'::timestamptz, NULL
        )
    ),
    1::numeric,
    'a null fractional_credit should fall back to full credit'
);

--
-- Non-destructive, which is the whole point of the split. The script this
-- replaces opened by deleting the student quiz_grade, quiz_answer and
-- quiz_submission rows before writing the deadline, under a name that said
-- nothing about it. User 1 sat quiz 1 and scored 13; all four grants above
-- targeted exactly that pair.
--

SELECT results_eq(
    $$ SELECT points FROM api.quiz_grades WHERE quiz_id = 1 AND user_id = 1 $$,
    $$ VALUES (13::real) $$,
    'granting a quiz extension should leave the grade already recorded alone'
);

SELECT is(
    (SELECT count(*)::int FROM api.quiz_submissions WHERE quiz_id = 1 AND user_id = 1),
    1,
    'granting a quiz extension should leave the quiz submission alone'
);

SELECT results_eq(
    $$
        SELECT event_type, points
        FROM api.quiz_grade_events
        WHERE quiz_id = 1 AND user_id = 1
        ORDER BY id
    $$,
    $$ VALUES ('recorded'::text, 13::real) $$,
    'granting a quiz extension should append nothing to quiz grade history'
);

-- The third table the script deletes from. It has not existed since quizzes
-- went paper-only, so the script raises before it writes the deadline at all.
SELECT hasnt_table(
    'data', 'quiz_answer',
    'data.quiz_answer should not exist, so nothing should be written to delete from it'
);

select * from finish();
rollback;
