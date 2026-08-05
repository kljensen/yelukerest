-- Tests for the append-only assignment field submission audit history
-- and the optimistic-concurrency (stale write) protection added for
-- issue #262.
begin;
select * from no_plan();

SELECT view_owner_is(
    'api', 'assignment_field_submission_events', 'api',
    'api.assignment_field_submission_events view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignment_field_submission_events', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on api.assignment_field_submission_events'
);

SELECT table_privs_are(
    'api', 'assignment_field_submission_events', 'student', ARRAY[]::text[],
    'students should have no privileges on api.assignment_field_submission_events'
);

SELECT table_privs_are(
    'api', 'assignment_field_submission_events', 'ta', ARRAY[]::text[],
    'tas should have no privileges on api.assignment_field_submission_events'
);

-- Set up an assignment submission and free-form fields to write against.
INSERT INTO api.assignment_fields (assignment_slug, slug, label, help, placeholder, pattern, example)
VALUES
    ('exam-1', 'audit-field', 'Audit field', 'For audit tests', 'text', '.*', ''),
    ('exam-1', 'audit-field-2', 'Audit field 2', 'For audit tests', 'text', '.*', '');

set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';

INSERT INTO api.assignment_submissions (id, assignment_slug, user_id, submitter_user_id)
VALUES (6001, 'exam-1', 3, 3);

-- ---------------------------------------------------------------
-- INSERT produces a 'submitted' event capturing hash and length
-- ---------------------------------------------------------------
INSERT INTO api.assignment_field_submissions
    (assignment_submission_id, assignment_field_slug, assignment_slug, body)
VALUES (6001, 'audit-field', 'exam-1', 'first draft');

SELECT results_eq(
    $$
        SELECT
            event_type,
            operation,
            assignment_slug,
            body_sha256,
            body_length,
            submitter_user_id,
            created_by_user_id
        FROM api.assignment_field_submission_events
        WHERE assignment_submission_id = 6001
        AND assignment_field_slug = 'audit-field'
        ORDER BY id
    $$,
    $$
        VALUES (
            'submitted'::text,
            'insert'::text,
            'exam-1'::text,
            encode(public.digest('first draft', 'sha256'), 'hex'),
            11,
            3,
            3
        )
    $$,
    'inserting a field submission should append a submitted event with body hash and length'
);

-- ---------------------------------------------------------------
-- UPDATE produces a 'revised' event
-- ---------------------------------------------------------------
UPDATE api.assignment_field_submissions
SET body = 'second draft'
WHERE assignment_submission_id = 6001
AND assignment_field_slug = 'audit-field';

SELECT results_eq(
    $$
        SELECT event_type, operation, body_sha256, body_length
        FROM api.assignment_field_submission_events
        WHERE assignment_submission_id = 6001
        AND assignment_field_slug = 'audit-field'
        ORDER BY id DESC
        LIMIT 1
    $$,
    $$
        VALUES (
            'revised'::text,
            'update'::text,
            encode(public.digest('second draft', 'sha256'), 'hex'),
            12
        )
    $$,
    'updating a field submission should append a revised event'
);

-- ---------------------------------------------------------------
-- Stale-write protection: mismatched updated_at is rejected
-- ---------------------------------------------------------------
SELECT throws_like(
    $$
        UPDATE api.assignment_field_submissions
        SET body = 'stale draft', updated_at = updated_at - interval '1 hour'
        WHERE assignment_submission_id = 6001
        AND assignment_field_slug = 'audit-field'
    $$,
    '%stale write rejected%',
    'updates supplying a mismatched updated_at should be rejected as stale'
);

SELECT throws_ok(
    $$
        UPDATE api.assignment_field_submissions
        SET body = 'stale draft', updated_at = updated_at - interval '1 hour'
        WHERE assignment_submission_id = 6001
        AND assignment_field_slug = 'audit-field'
    $$,
    'PT409',
    NULL,
    'stale writes should be rejected with SQLSTATE PT409 (HTTP 409 through PostgREST)'
);

SELECT lives_ok(
    $$
        UPDATE api.assignment_field_submissions
        SET body = 'third draft', updated_at = updated_at
        WHERE assignment_submission_id = 6001
        AND assignment_field_slug = 'audit-field'
    $$,
    'updates supplying the matching updated_at should succeed'
);

SELECT lives_ok(
    $$
        UPDATE api.assignment_field_submissions
        SET body = 'fourth draft'
        WHERE assignment_submission_id = 6001
        AND assignment_field_slug = 'audit-field'
    $$,
    'updates omitting updated_at should skip the stale-write check'
);

-- ---------------------------------------------------------------
-- created_at cannot drift: API inserts get the server clock and
-- updates cannot rewrite it
-- ---------------------------------------------------------------
SELECT results_eq(
    $$
        INSERT INTO api.assignment_field_submissions
            (assignment_submission_id, assignment_field_slug, assignment_slug, body, created_at)
        VALUES (6001, 'audit-field-2', 'exam-1', 'clock check', '2000-01-01T00:00:00Z')
        RETURNING created_at > '2020-01-01'::timestamptz
    $$,
    ARRAY[true],
    'API inserts should ignore client-supplied created_at values'
);

SELECT results_eq(
    $$
        UPDATE api.assignment_field_submissions
        SET body = 'clock check 2', created_at = '2000-01-01T00:00:00Z'
        WHERE assignment_submission_id = 6001
        AND assignment_field_slug = 'audit-field-2'
        RETURNING created_at > '2020-01-01'::timestamptz
    $$,
    ARRAY[true],
    'updates should not be able to rewrite created_at'
);

-- ---------------------------------------------------------------
-- DELETE produces a 'deleted' event
-- ---------------------------------------------------------------
DELETE FROM api.assignment_field_submissions
WHERE assignment_submission_id = 6001
AND assignment_field_slug = 'audit-field-2';

SELECT results_eq(
    $$
        SELECT event_type, operation
        FROM api.assignment_field_submission_events
        WHERE assignment_submission_id = 6001
        AND assignment_field_slug = 'audit-field-2'
        ORDER BY id DESC
        LIMIT 1
    $$,
    $$ VALUES ('deleted'::text, 'delete'::text) $$,
    'deleting a field submission should append a deleted event'
);

-- ---------------------------------------------------------------
-- Students cannot read the history
-- ---------------------------------------------------------------
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT throws_like(
    $$ SELECT count(*) FROM api.assignment_field_submission_events $$,
    '%permission denied%',
    'students should not be able to read assignment field submission events'
);

-- ---------------------------------------------------------------
-- The history table is append-only
-- ---------------------------------------------------------------
reset role;

SELECT throws_like(
    $$ UPDATE data.assignment_field_submission_event SET body_length = 0 WHERE id = (SELECT max(id) FROM data.assignment_field_submission_event) $$,
    '%append-only%',
    'assignment field submission events should reject UPDATE'
);

SELECT throws_like(
    $$ DELETE FROM data.assignment_field_submission_event WHERE id = (SELECT max(id) FROM data.assignment_field_submission_event) $$,
    '%append-only%',
    'assignment field submission events should reject DELETE'
);

select * from finish();
rollback;
