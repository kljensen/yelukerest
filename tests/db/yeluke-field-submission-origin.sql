-- `origin` on assignment field submissions (issue #370): how a row first came
-- to exist, and the fact that it never changes afterwards.
--
-- The security half of this file is the point. Grants on
-- api.assignment_field_submissions are table-wide, not column-scoped: student
-- and ta hold INSERT and UPDATE on the whole view, so once the column exists
-- they can name it in a payload. Nothing but the BEFORE trigger stops a
-- student claiming their own paste was provisioned for them, or relabelling an
-- auto-populated row as their own work. Neither of the two tests below passes
-- against a trigger that merely accepts what the client sent.
select * from no_plan();

-- Start from no request identity at all. A claim leaked from an earlier file
-- would make the direct-write cases below look like API writes, which is
-- exactly the distinction under test.
SELECT set_config('request.jwt.claim.role', '', false);
SELECT set_config('request.jwt.claim.user_id', '', false);
SELECT set_config('request.jwt.claims', '', false);

-- ---------------------------------------------------------------- fixtures --
-- An open individual assignment owned by user 1 (a student), so a student
-- write to it is admitted by row-level security.
INSERT INTO data.assignment (slug, points_possible, is_draft, is_team, title, body, closed_at)
VALUES ('zz-origin', 10, false, false, 'origin fixture', '', current_timestamp + '30 days'::interval);

INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder)
VALUES
    ('repo-url', 'zz-origin', 'Repo URL', 'help', 'placeholder'),
    ('other-url', 'zz-origin', 'Other URL', 'help', 'placeholder'),
    ('third-url', 'zz-origin', 'Third URL', 'help', 'placeholder'),
    ('unlabelled-url', 'zz-origin', 'Unlabelled URL', 'help', 'placeholder'),
    ('roleless-url', 'zz-origin', 'Roleless URL', 'help', 'placeholder'),
    ('roleless-refused-url', 'zz-origin', 'Roleless refused URL', 'help', 'placeholder'),
    ('batch-a-url', 'zz-origin', 'Batch A URL', 'help', 'placeholder'),
    ('batch-b-url', 'zz-origin', 'Batch B URL', 'help', 'placeholder');

INSERT INTO data.assignment_submission (id, assignment_slug, user_id, is_team, submitter_user_id)
VALUES (7370, 'zz-origin', 1, false, 1);

-- ------------------------------------------------- the column is exposed ----
-- `create view ... select *` freezes its column list at creation time, so a
-- view that was not recreated by the migration still serves the old columns
-- and every API reader stays blind to provenance.
SELECT ok(
    (
        SELECT count(*) = 2
        FROM information_schema.columns
        WHERE table_schema = 'api'
        AND table_name IN ('assignment_field_submissions', 'assignment_field_submission_events')
        AND column_name = 'origin'
    ),
    'both api views should expose the origin column'
);

-- ------------------------- a write with no identity must say how it arose ---
-- Deliberately not defaulted: defaulting no-identity writes to any one value
-- would put a psql repair, a loader and `admin provision-repos` back under one
-- indistinguishable label, which is the ambiguity the column exists to remove.
-- On its own field slug, so that a trigger which wrongly lets this through
-- does not also collide with the row below and abort the file: a broken
-- implementation has to fail the assertions that name it, not hide behind a
-- duplicate key.
SELECT throws_like(
    $$
        INSERT INTO data.assignment_field_submission
            (assignment_submission_id, assignment_field_slug, body)
        VALUES (7370, 'unlabelled-url', 'https://github.com/example/unlabelled')
    $$,
    '%must state its origin%',
    'a direct write with no request identity and no origin should be refused'
);

SELECT results_eq(
    $$
        INSERT INTO data.assignment_field_submission
            (assignment_submission_id, assignment_field_slug, body, origin)
        VALUES (7370, 'repo-url', 'https://github.com/example/provisioned', 'provisioning')
        RETURNING origin
    $$,
    ARRAY['provisioning'],
    'a direct write may state its own origin, which is what admin provision-repos does'
);

-- A user id on its own is not a classifiable identity either. A direct session
-- that sets request.jwt.claim.user_id and no role -- which is what several
-- trusted writers and tests look like -- gets no automatic classification:
-- inferring `staff` from "not a student" would be guessing at exactly the
-- question the column exists to answer.
SET LOCAL request.jwt.claim.user_id = '1';

-- On its own field slug, for the same reason as the case above: a trigger that
-- wrongly guesses here must fail this assertion, not hide behind a duplicate
-- key raised by the next statement.
SELECT throws_like(
    $$
        INSERT INTO data.assignment_field_submission
            (assignment_submission_id, assignment_field_slug, body)
        VALUES (7370, 'roleless-refused-url', 'https://github.com/example/roleless')
    $$,
    '%must state its origin%',
    'a write with a user id but no role should be refused rather than classified'
);

SELECT results_eq(
    $$
        INSERT INTO data.assignment_field_submission
            (assignment_submission_id, assignment_field_slug, body, origin)
        VALUES (7370, 'roleless-url', 'https://github.com/example/roleless', 'import')
        RETURNING origin
    $$,
    ARRAY['import'],
    'a write with a user id but no role may still state its own origin'
);

SET LOCAL request.jwt.claim.user_id = '';

SELECT throws_like(
    $$
        INSERT INTO data.assignment_field_submission
            (assignment_submission_id, assignment_field_slug, body, origin)
        VALUES (7370, 'third-url', 'https://example.com/nonsense', 'whatever')
    $$,
    '%origin_is_known%',
    'origin should be constrained to the known vocabulary'
);

-- The history copies the submission row's origin rather than deciding one, or
-- the row and its history could tell different stories about the same write.
SELECT results_eq(
    $$
        SELECT event_type, origin
        FROM data.assignment_field_submission_event
        WHERE assignment_submission_id = 7370 AND assignment_field_slug = 'repo-url'
        ORDER BY id
    $$,
    $$ VALUES ('submitted'::text, 'provisioning'::text) $$,
    'the submitted event should carry the origin of the row it describes'
);

-- ------------------------------------- a student cannot choose an origin ----
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT results_eq(
    $$
        INSERT INTO api.assignment_field_submissions
            (assignment_submission_id, assignment_field_slug, assignment_slug, body, origin)
        VALUES (7370, 'other-url', 'zz-origin', 'https://github.com/example/mine', 'provisioning')
        RETURNING origin
    $$,
    ARRAY['student'],
    'a student naming origin = provisioning on INSERT should still land as student'
);

-- --------------------------- nor relabel a row written on their behalf ------
-- This is the case that matters. The provisioned row above is precisely one a
-- student is expected to revise, and revising it must not turn it into their
-- own claimed submission.
SELECT results_eq(
    $$
        UPDATE api.assignment_field_submissions
        SET body = 'https://github.com/example/edited-by-student', origin = 'student'
        WHERE assignment_submission_id = 7370 AND assignment_field_slug = 'repo-url'
        RETURNING origin
    $$,
    ARRAY['provisioning'],
    'a student naming a different origin on UPDATE should leave origin unchanged'
);

-- A student cannot launder the label through an ordinary body edit either.
SELECT results_eq(
    $$
        UPDATE api.assignment_field_submissions
        SET body = 'https://github.com/example/edited-again'
        WHERE assignment_submission_id = 7370 AND assignment_field_slug = 'repo-url'
        RETURNING origin
    $$,
    ARRAY['provisioning'],
    'an ordinary student edit should leave a provisioned origin in place'
);

-- The upsert PostgREST actually sends. `Prefer: resolution=merge-duplicates`
-- becomes INSERT ... ON CONFLICT DO UPDATE, which is the most plausible way to
-- reach the UPDATE path while naming `origin` in what looks like an insert
-- payload: the BEFORE INSERT fires first and canonicalises the proposed row,
-- then the conflict routes to BEFORE UPDATE, which restores OLD.origin.
SELECT results_eq(
    $$
        INSERT INTO api.assignment_field_submissions
            (assignment_submission_id, assignment_field_slug, assignment_slug, body, origin)
        VALUES (7370, 'repo-url', 'zz-origin', 'https://github.com/example/upserted', 'student')
        ON CONFLICT (assignment_submission_id, assignment_field_slug) DO UPDATE
            SET body = excluded.body, origin = excluded.origin
        RETURNING origin
    $$,
    ARRAY['provisioning'],
    'a student upsert over a provisioned row should leave origin unchanged'
);

-- A batch write is one statement affecting several rows, which is the shape
-- the Elm client's multi-field save takes. The trigger is FOR EACH ROW, so
-- each row is classified on its own; assert that rather than assume it.
SELECT results_eq(
    $$
        INSERT INTO api.assignment_field_submissions
            (assignment_submission_id, assignment_field_slug, assignment_slug, body, origin)
        VALUES
            (7370, 'batch-a-url', 'zz-origin', 'https://example.com/batch-a', 'provisioning'),
            (7370, 'batch-b-url', 'zz-origin', 'https://example.com/batch-b', 'import')
        RETURNING origin
    $$,
    ARRAY['student', 'student'],
    'every row of a multi-row student INSERT should be classified as student'
);

SELECT results_eq(
    $$
        UPDATE api.assignment_field_submissions
        SET body = body || '-edited', origin = 'provisioning'
        WHERE assignment_submission_id = 7370
        AND assignment_field_slug IN ('batch-a-url', 'batch-b-url')
        RETURNING origin
    $$,
    ARRAY['student', 'student'],
    'every row of a multi-row student UPDATE should keep the origin it had'
);

-- Reading the history needs the data schema, which no request role reaches;
-- the claims stay as they were, so this is still a read of what the student's
-- writes just recorded.
reset role;

-- Revising it is recorded, as it always was, by submitter_user_id and the
-- event actor. The origin still says the platform created the row.
SELECT results_eq(
    $$
        SELECT event_type, origin, created_by_user_id
        FROM data.assignment_field_submission_event
        WHERE assignment_submission_id = 7370 AND assignment_field_slug = 'repo-url'
        ORDER BY id DESC
        LIMIT 1
    $$,
    $$ VALUES ('revised'::text, 'provisioning'::text, 1) $$,
    'revising a provisioned row should append a revised event that keeps the provisioning origin'
);

-- ---------------------------------------------- staff writes say so ---------
set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';

SELECT results_eq(
    $$
        INSERT INTO api.assignment_field_submissions
            (assignment_submission_id, assignment_field_slug, assignment_slug, body, origin)
        VALUES (7370, 'third-url', 'zz-origin', 'https://example.com/by-staff', 'student')
        RETURNING origin
    $$,
    ARRAY['staff'],
    'a faculty write should be recorded as staff whatever origin the payload names'
);

-- A deletion event carries the origin the row had.
DELETE FROM api.assignment_field_submissions
WHERE assignment_submission_id = 7370 AND assignment_field_slug = 'third-url';

reset role;

SELECT results_eq(
    $$
        SELECT event_type, origin
        FROM data.assignment_field_submission_event
        WHERE assignment_submission_id = 7370 AND assignment_field_slug = 'third-url'
        ORDER BY id DESC
        LIMIT 1
    $$,
    $$ VALUES ('deleted'::text, 'staff'::text) $$,
    'the deleted event should carry the origin the row had'
);

select * from finish();
