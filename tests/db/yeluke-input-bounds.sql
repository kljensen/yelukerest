-- Tests for the authoritative input size bounds added for issue #262.
-- Every bound gets an accept-at-limit case and a reject-over-limit case.
-- These are pure constraint tests, so we write to the data schema as the
-- superuser rather than exercising RLS (covered by other test files).
select * from no_plan();

-- ---------------------------------------------------------------
-- text_is_url length bound
-- ---------------------------------------------------------------
select ok(
    data.text_is_url('https://a' || repeat('x', 2039)),
    'text_is_url should accept URLs of exactly 2048 characters'
);

select ok(
    not data.text_is_url('https://a' || repeat('x', 2040)),
    'text_is_url should reject URLs longer than 2048 characters'
);

-- ---------------------------------------------------------------
-- Setup rows used below
-- ---------------------------------------------------------------
INSERT INTO data.assignment_submission (id, assignment_slug, is_team, user_id, submitter_user_id)
VALUES (6100, 'exam-1', false, 1, 1);

INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder, pattern, example)
VALUES ('freeform', 'exam-1', 'Freeform', 'Anything goes', 'text', '.*', '');

-- ---------------------------------------------------------------
-- assignment_field_submission.body: 64 KiB cap
-- ---------------------------------------------------------------
SELECT throws_like(
    $$
        INSERT INTO data.assignment_field_submission
            (assignment_submission_id, assignment_field_slug, assignment_slug, body, submitter_user_id)
        VALUES (6100, 'freeform', 'exam-1', repeat('x', 65537), 1)
    $$,
    '%body_max_length%',
    'assignment_field_submission should reject bodies larger than 65536 bytes'
);

SELECT lives_ok(
    $$
        INSERT INTO data.assignment_field_submission
            (assignment_submission_id, assignment_field_slug, assignment_slug, body, submitter_user_id)
        VALUES (6100, 'freeform', 'exam-1', repeat('x', 65536), 1)
    $$,
    'assignment_field_submission should accept bodies of exactly 65536 bytes'
);

-- ---------------------------------------------------------------
-- assignment_field_submission updated_after_created
-- (direct load with a future created_at leaves updated_at behind it)
-- ---------------------------------------------------------------
SELECT throws_like(
    $$
        INSERT INTO data.assignment_field_submission
            (assignment_submission_id, assignment_field_slug, assignment_slug, body, submitter_user_id, created_at)
        VALUES (6100, 'profound', 'exam-1', 'profound words', 1, current_timestamp + interval '1 day')
    $$,
    '%updated_after_created%',
    'assignment_field_submission should reject created_at after updated_at'
);

-- ---------------------------------------------------------------
-- assignment_field.pattern (512) and .example (1024)
-- ---------------------------------------------------------------
SELECT lives_ok(
    $$
        INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder, pattern, example)
        VALUES ('bound-pattern-ok', 'exam-1', 'L', 'H', 'P', repeat('a', 512), repeat('a', 512))
    $$,
    'assignment_field should accept patterns of exactly 512 characters'
);

SELECT throws_like(
    $$
        INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder, pattern, example)
        VALUES ('bound-pattern-bad', 'exam-1', 'L', 'H', 'P', repeat('a', 513), repeat('a', 513))
    $$,
    '%violates check constraint%',
    'assignment_field should reject patterns longer than 512 characters'
);

SELECT lives_ok(
    $$
        INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder, pattern, example)
        VALUES ('bound-example-ok', 'exam-1', 'L', 'H', 'P', '.*', repeat('e', 1024))
    $$,
    'assignment_field should accept examples of exactly 1024 characters'
);

SELECT throws_like(
    $$
        INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder, pattern, example)
        VALUES ('bound-example-bad', 'exam-1', 'L', 'H', 'P', '.*', repeat('e', 1025))
    $$,
    '%violates check constraint%',
    'assignment_field should reject examples longer than 1024 characters'
);

-- ---------------------------------------------------------------
-- assignment.body: 256 KiB cap
-- ---------------------------------------------------------------
SELECT lives_ok(
    $$ UPDATE data.assignment SET body = repeat('x', 262144) WHERE slug = 'js-koans' $$,
    'assignment should accept bodies of exactly 262144 bytes'
);

SELECT throws_like(
    $$ UPDATE data.assignment SET body = repeat('x', 262145) WHERE slug = 'js-koans' $$,
    '%assignment_body_check%',
    'assignment should reject bodies larger than 262144 bytes'
);

-- ---------------------------------------------------------------
-- meeting.description (256 KiB), .summary (4 KiB), .duration (24h)
-- ---------------------------------------------------------------
SELECT lives_ok(
    $$ UPDATE data.meeting SET description = repeat('x', 262144) WHERE slug = 'intro' $$,
    'meeting should accept descriptions of exactly 262144 bytes'
);

SELECT throws_like(
    $$ UPDATE data.meeting SET description = repeat('x', 262145) WHERE slug = 'intro' $$,
    '%meeting_description_check%',
    'meeting should reject descriptions larger than 262144 bytes'
);

SELECT lives_ok(
    $$ UPDATE data.meeting SET summary = repeat('x', 4096) WHERE slug = 'intro' $$,
    'meeting should accept summaries of exactly 4096 bytes'
);

SELECT throws_like(
    $$ UPDATE data.meeting SET summary = repeat('x', 4097) WHERE slug = 'intro' $$,
    '%meeting_summary_check%',
    'meeting should reject summaries larger than 4096 bytes'
);

SELECT lives_ok(
    $$ UPDATE data.meeting SET duration = interval '24 hours' WHERE slug = 'intro' $$,
    'meeting should accept durations of exactly 24 hours'
);

SELECT throws_like(
    $$ UPDATE data.meeting SET duration = interval '24 hours 1 second' WHERE slug = 'intro' $$,
    '%meeting_duration_max%',
    'meeting should reject durations longer than 24 hours'
);

-- ---------------------------------------------------------------
-- quiz.duration: positive and at most 24h
-- ---------------------------------------------------------------
SELECT lives_ok(
    $$ UPDATE data.quiz SET duration = interval '24 hours' WHERE id = 1 $$,
    'quiz should accept durations of exactly 24 hours'
);

SELECT throws_like(
    $$ UPDATE data.quiz SET duration = interval '24 hours 1 second' WHERE id = 1 $$,
    '%quiz_duration_max%',
    'quiz should reject durations longer than 24 hours'
);

SELECT throws_like(
    $$ UPDATE data.quiz SET duration = interval '0 seconds' WHERE id = 1 $$,
    '%quiz_duration_positive%',
    'quiz should reject non-positive durations'
);

-- ---------------------------------------------------------------
-- ui_element.body: 64 KiB cap
-- ---------------------------------------------------------------
SELECT lives_ok(
    $$ UPDATE data.ui_element SET body = repeat('x', 65536) WHERE key = 'course-name' $$,
    'ui_element should accept bodies of exactly 65536 bytes'
);

SELECT throws_like(
    $$ UPDATE data.ui_element SET body = repeat('x', 65537) WHERE key = 'course-name' $$,
    '%ui_element_body_check%',
    'ui_element should reject bodies larger than 65536 bytes'
);

-- ---------------------------------------------------------------
-- user_secret.body: 8 KiB cap
-- ---------------------------------------------------------------
SELECT lives_ok(
    $$ UPDATE data.user_secret SET body = repeat('x', 8192) WHERE slug = 'foo' AND user_id = 1 $$,
    'user_secret should accept bodies of exactly 8192 bytes'
);

SELECT throws_like(
    $$ UPDATE data.user_secret SET body = repeat('x', 8193) WHERE slug = 'foo' AND user_id = 1 $$,
    '%user_secret_body_check%',
    'user_secret should reject bodies larger than 8192 bytes'
);

-- ---------------------------------------------------------------
-- Grade description bounds: 8 KiB each
-- ---------------------------------------------------------------
SELECT lives_ok(
    $$ UPDATE data.assignment_grade SET description = repeat('x', 8192) WHERE assignment_submission_id = 1 $$,
    'assignment_grade should accept descriptions of exactly 8192 bytes'
);

SELECT throws_like(
    $$ UPDATE data.assignment_grade SET description = repeat('x', 8193) WHERE assignment_submission_id = 1 $$,
    '%assignment_grade_description_check%',
    'assignment_grade should reject descriptions larger than 8192 bytes'
);

SELECT lives_ok(
    $$ UPDATE data.quiz_grade SET description = repeat('x', 8192) WHERE quiz_id = 1 AND user_id = 1 $$,
    'quiz_grade should accept descriptions of exactly 8192 bytes'
);

SELECT throws_like(
    $$ UPDATE data.quiz_grade SET description = repeat('x', 8193) WHERE quiz_id = 1 AND user_id = 1 $$,
    '%quiz_grade_description_check%',
    'quiz_grade should reject descriptions larger than 8192 bytes'
);

SELECT lives_ok(
    $$ UPDATE data.grade SET description = repeat('x', 8192) WHERE snapshot_slug = 'after-first-exam' AND user_id = 1 $$,
    'grade should accept descriptions of exactly 8192 bytes'
);

SELECT throws_like(
    $$ UPDATE data.grade SET description = repeat('x', 8193) WHERE snapshot_slug = 'after-first-exam' AND user_id = 1 $$,
    '%grade_description_check%',
    'grade should reject descriptions larger than 8192 bytes'
);

SELECT lives_ok(
    $$ UPDATE data.grade_snapshot SET description = repeat('x', 8192) WHERE slug = 'after-first-exam' $$,
    'grade_snapshot should accept descriptions of exactly 8192 bytes'
);

SELECT throws_like(
    $$ UPDATE data.grade_snapshot SET description = repeat('x', 8193) WHERE slug = 'after-first-exam' $$,
    '%grade_snapshot_description_check%',
    'grade_snapshot should reject descriptions larger than 8192 bytes'
);

-- ---------------------------------------------------------------
-- grade.points and grade_event.points: at most 100000
-- ---------------------------------------------------------------
SELECT lives_ok(
    $$ UPDATE data.grade SET points = 100000 WHERE snapshot_slug = 'after-first-exam' AND user_id = 1 $$,
    'grade should accept points of exactly 100000'
);

SELECT throws_like(
    $$ UPDATE data.grade SET points = 100001 WHERE snapshot_slug = 'after-first-exam' AND user_id = 1 $$,
    '%grade_points_finite_nonnegative%',
    'grade should reject points larger than 100000'
);

SELECT lives_ok(
    $$
        INSERT INTO data.grade_event
            (event_type, operation, snapshot_slug, user_id, points, grade_created_at, grade_updated_at)
        VALUES ('recorded', 'insert', 'after-first-exam', 1, 100000, current_timestamp, current_timestamp)
    $$,
    'grade_event should accept points of exactly 100000'
);

SELECT throws_like(
    $$
        INSERT INTO data.grade_event
            (event_type, operation, snapshot_slug, user_id, points, grade_created_at, grade_updated_at)
        VALUES ('recorded', 'insert', 'after-first-exam', 1, 100001, current_timestamp, current_timestamp)
    $$,
    '%grade_event_points_finite_nonnegative%',
    'grade_event should reject points larger than 100000'
);

-- ---------------------------------------------------------------
-- artifact.url (2048 chars), .content_type (255 chars),
-- .content_length (5 GiB)
-- ---------------------------------------------------------------
SELECT lives_ok(
    $$
        INSERT INTO data.artifact (user_id, slug, title, url)
        VALUES (1, 'bound-url-ok', 'Bound URL', 'https://a' || repeat('x', 2039))
    $$,
    'artifact should accept URLs of exactly 2048 characters'
);

SELECT throws_like(
    $$
        INSERT INTO data.artifact (user_id, slug, title, url)
        VALUES (1, 'bound-url-bad', 'Bound URL', 'https://a' || repeat('x', 2040))
    $$,
    '%artifact_url_check%',
    'artifact should reject URLs longer than 2048 characters'
);

SELECT lives_ok(
    $$
        INSERT INTO data.artifact (user_id, slug, title, url, content_type)
        VALUES (1, 'bound-ctype-ok', 'Bound content type', 'https://example.com/a', 'a/' || repeat('b', 253))
    $$,
    'artifact should accept content types of exactly 255 characters'
);

SELECT throws_like(
    $$
        INSERT INTO data.artifact (user_id, slug, title, url, content_type)
        VALUES (1, 'bound-ctype-bad', 'Bound content type', 'https://example.com/a', 'a/' || repeat('b', 254))
    $$,
    '%artifact_content_type_check%',
    'artifact should reject content types longer than 255 characters'
);

SELECT lives_ok(
    $$
        INSERT INTO data.artifact (user_id, slug, title, url, content_length)
        VALUES (1, 'bound-clen-ok', 'Bound content length', 'https://example.com/a', 5368709120)
    $$,
    'artifact should accept content lengths of exactly 5 GiB'
);

SELECT throws_like(
    $$
        INSERT INTO data.artifact (user_id, slug, title, url, content_length)
        VALUES (1, 'bound-clen-bad', 'Bound content length', 'https://example.com/a', 5368709121)
    $$,
    '%artifact_content_length_check%',
    'artifact should reject content lengths larger than 5 GiB'
);

select * from finish();
