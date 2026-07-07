begin;
select plan(30);

SELECT view_owner_is(
    'api', 'assignment_grade_events', 'api',
    'api.assignment_grade_events view should be owned by the api role'
);

SELECT view_owner_is(
    'api', 'quiz_grade_events', 'api',
    'api.quiz_grade_events view should be owned by the api role'
);

SELECT view_owner_is(
    'api', 'grade_events', 'api',
    'api.grade_events view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignment_grade_events', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on view "api.assignment_grade_events"'
);

SELECT table_privs_are(
    'api', 'quiz_grade_events', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on view "api.quiz_grade_events"'
);

SELECT table_privs_are(
    'api', 'grade_events', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on view "api.grade_events"'
);

SELECT table_privs_are(
    'api', 'assignment_grade_events', 'student', ARRAY[]::text[],
    'students should not be granted access to assignment grade history'
);

SELECT table_privs_are(
    'api', 'quiz_grade_events', 'student', ARRAY[]::text[],
    'students should not be granted access to quiz grade history'
);

SELECT table_privs_are(
    'api', 'grade_events', 'student', ARRAY[]::text[],
    'students should not be granted access to grade snapshot history'
);

SELECT table_privs_are(
    'data', 'assignment_grade_event', 'faculty', ARRAY[]::text[],
    'faculty should have no direct privileges on data.assignment_grade_event'
);

SELECT table_privs_are(
    'data', 'quiz_grade_event', 'faculty', ARRAY[]::text[],
    'faculty should have no direct privileges on data.quiz_grade_event'
);

SELECT table_privs_are(
    'data', 'grade_event', 'faculty', ARRAY[]::text[],
    'faculty should have no direct privileges on data.grade_event'
);

set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select * from api.assignment_grade_events',
    '%permission denied%',
    'anonymous users should not be able to use assignment grade history'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT throws_like(
    'select * from api.quiz_grade_events',
    '%permission denied%',
    'students should not be able to use quiz grade history'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '5';

SELECT is(
    (SELECT count(*)::int FROM api.assignment_grade_events WHERE event_type = 'recorded'),
    4,
    'sample assignment grades should have recorded events'
);

SELECT is(
    (SELECT count(*)::int FROM api.quiz_grade_events WHERE event_type = 'recorded'),
    2,
    'sample quiz grades should have recorded events'
);

SELECT is(
    (SELECT count(*)::int FROM api.grade_events WHERE event_type = 'recorded'),
    4,
    'sample grade snapshot rows should have recorded events'
);

UPDATE api.assignment_grades
SET points = 12, description = 'regraded'
WHERE assignment_submission_id = 1;

SELECT results_eq(
    $$
        SELECT event_type
        FROM api.assignment_grade_events
        WHERE assignment_submission_id = 1
        ORDER BY id
    $$,
    ARRAY['recorded', 'corrected'],
    'assignment regrades should append a correction event'
);

SELECT results_eq(
    $$
        SELECT points::numeric
        FROM api.assignment_grade_events
        WHERE assignment_submission_id = 1
        ORDER BY id
    $$,
    ARRAY[50::numeric, 12::numeric],
    'assignment grade history should preserve old and new points'
);

SELECT is(
    (
        SELECT created_by_user_id
        FROM api.assignment_grade_events
        WHERE assignment_submission_id = 1
        ORDER BY id DESC
        LIMIT 1
    ),
    5,
    'assignment grade correction should capture request user id'
);

DELETE FROM api.assignment_grades
WHERE assignment_submission_id = 1;

SELECT results_eq(
    $$
        SELECT event_type
        FROM api.assignment_grade_events
        WHERE assignment_submission_id = 1
        ORDER BY id
    $$,
    ARRAY['recorded', 'corrected', 'voided'],
    'assignment grade deletes should append a void event'
);

UPDATE api.quiz_grades
SET points = 10
WHERE quiz_id = 1
AND user_id = 1;

SELECT results_eq(
    $$
        SELECT event_type
        FROM api.quiz_grade_events
        WHERE quiz_id = 1
        AND user_id = 1
        ORDER BY id
    $$,
    ARRAY['recorded', 'corrected'],
    'quiz regrades should append a correction event'
);

SELECT results_eq(
    $$
        SELECT points::numeric
        FROM api.quiz_grade_events
        WHERE quiz_id = 1
        AND user_id = 1
        ORDER BY id
    $$,
    ARRAY[13::numeric, 10::numeric],
    'quiz grade history should preserve old and new points'
);

DELETE FROM api.quiz_grades
WHERE quiz_id = 1
AND user_id = 1;

SELECT results_eq(
    $$
        SELECT event_type
        FROM api.quiz_grade_events
        WHERE quiz_id = 1
        AND user_id = 1
        ORDER BY id
    $$,
    ARRAY['recorded', 'corrected', 'voided'],
    'quiz grade deletes should append a void event'
);

UPDATE api.grades
SET points = 49
WHERE snapshot_slug = 'after-first-exam'
AND user_id = 1;

SELECT results_eq(
    $$
        SELECT event_type
        FROM api.grade_events
        WHERE snapshot_slug = 'after-first-exam'
        AND user_id = 1
        ORDER BY id
    $$,
    ARRAY['recorded', 'corrected'],
    'snapshot grade corrections should append a correction event'
);

SELECT results_eq(
    $$
        SELECT points::numeric
        FROM api.grade_events
        WHERE snapshot_slug = 'after-first-exam'
        AND user_id = 1
        ORDER BY id
    $$,
    ARRAY[50::numeric, 49::numeric],
    'snapshot grade history should preserve old and new points'
);

DELETE FROM api.grades
WHERE snapshot_slug = 'after-first-exam'
AND user_id = 1;

SELECT results_eq(
    $$
        SELECT event_type
        FROM api.grade_events
        WHERE snapshot_slug = 'after-first-exam'
        AND user_id = 1
        ORDER BY id
    $$,
    ARRAY['recorded', 'corrected', 'voided'],
    'snapshot grade deletes should append a void event'
);

RESET ROLE;

SELECT throws_like(
    $$
        UPDATE data.assignment_grade_event
        SET reason = 'rewrite history'
        WHERE assignment_submission_id = 1
    $$,
    '%append-only%',
    'assignment grade events should reject updates'
);

SELECT throws_like(
    $$
        DELETE FROM data.quiz_grade_event
        WHERE quiz_id = 1
        AND user_id = 1
    $$,
    '%append-only%',
    'quiz grade events should reject deletes'
);

SELECT throws_like(
    $$
        UPDATE data.grade_event
        SET reason = 'rewrite history'
        WHERE snapshot_slug = 'after-first-exam'
        AND user_id = 1
    $$,
    '%append-only%',
    'snapshot grade events should reject updates'
);

select * from finish();
rollback;
