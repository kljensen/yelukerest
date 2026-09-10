-- api.my_assignments: one me-scoped row per assignment (issue #380).
--
-- Each rule the view's columns follow is pinned here, so a change to the view
-- names the case it broke rather than a whole migration.
--
-- Sample data in play: user 1 (student, bright-fog) owns submission 1 on
-- team-selection and is a participant of team submission 4 on
-- project-update-1; user 2 (student, hazy-mountain) owns submission 2 on
-- team-selection and its team holds an exception on project-update-1; user 3
-- (faculty, bright-fog) owns submission 3; user 4 (ta) is on no team; user 5
-- holds an exception on team-selection.
SELECT plan(28)
;
-- Three individual assignments to tell the deadline cases apart, each with a
-- field so fields_total is not zero.
INSERT INTO data.assignment (slug, points_possible, is_draft, is_team, title, body, closed_at)
VALUES
    ('zz-my-past', 10, false, false, 'Past', 'b', current_timestamp - '1 day'::interval),
    ('zz-my-open', 10, false, false, 'Open', 'b', current_timestamp + '30 days'::interval),
    ('zz-my-draft', 10, true, false, 'Draft', 'b', current_timestamp + '30 days'::interval)
; INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder, is_url, is_multiline)
VALUES
    ('url', 'zz-my-past', 'l', 'h', 'p', false, false),
    ('one', 'zz-my-open', 'l', 'h', 'p', false, false),
    ('two', 'zz-my-open', 'l', 'h', 'p', false, false),
    ('url', 'zz-my-draft', 'l', 'h', 'p', false, false)
;
-- User 1's exceptions, in order: later than the deadline (the extension
-- applies); earlier than the deadline (greatest wins, it does not close the
-- assignment); live on a draft (draft is evaluated first).
INSERT INTO data.assignment_grade_exception (assignment_slug, user_id, closed_at, fractional_credit)
VALUES
    ('zz-my-past', 1, current_timestamp + '30 days'::interval, 0.8),
    ('zz-my-open', 1, current_timestamp - '1 day'::interval, 0.5),
    ('zz-my-draft', 1, current_timestamp + '30 days'::interval, 1)
;
-- Become user 1: role AND user id, which is what an API request carries.
SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
;
--
-- Shape: one row per visible assignment, drafts included, with is_open and
-- closed_at copied through unchanged.
--
SELECT
    "is"((
        SELECT count(*)
        FROM api.my_assignments
    ), (
        SELECT count(*)
        FROM api.assignments
    ), 'one row per assignment the caller can see, drafts included')
; SELECT is_empty('
        SELECT m.slug
        FROM api.my_assignments m
        JOIN api.assignments a USING (slug)
        WHERE m.is_open IS DISTINCT FROM a.is_open
           OR m.closed_at IS DISTINCT FROM a.closed_at
           OR m.created_at IS DISTINCT FROM a.created_at
           OR m.updated_at IS DISTINCT FROM a.updated_at
    ', 'is_open, closed_at, created_at and updated_at mean exactly what they mean on api.assignments')
;
--
-- No exception: the assignment''s own deadline is the effective one. User 5
-- holds an exception on team-selection; user 1 must not see it.
--
SELECT results_eq('
        SELECT effective_closed_at = closed_at AS deadline_stands,
               extension_closed_at IS NULL AS no_extension,
               extension_fractional_credit IS NULL AS no_credit,
               submission_window_open, can_submit, can_submit_reason
        FROM api.my_assignments
        WHERE slug = ''team-selection''
    ', ' VALUES (true, true, true, true, true, NULL::text) ', 'with no exception the effective deadline is closed_at and the extension columns are NULL')
;
--
-- Submissions: the caller''s own, with the contracted keys, the field count,
-- and the stored grade.
--
SELECT results_eq('
        SELECT jsonb_array_length(submissions) AS n,
               submissions -> 0 ?& ARRAY[''id'', ''team_nickname'', ''created_at'', ''updated_at'', ''fields_submitted'', ''fields_total'', ''grade''] AS has_keys,
               (submissions -> 0 ->> ''id'')::int AS id,
               submissions -> 0 ->> ''team_nickname'' AS team_nickname,
               (submissions -> 0 ->> ''fields_submitted'')::int AS fields_submitted,
               (submissions -> 0 ->> ''fields_total'')::int AS fields_total,
               (submissions -> 0 -> ''grade'' ->> ''points'')::real AS points,
               submissions -> 0 -> ''grade'' ->> ''description'' AS description
        FROM api.my_assignments
        WHERE slug = ''team-selection''
    ', ' VALUES (1, true, 1, NULL::text, 1, 1, 50::real, ''Foo bar bax boo this is your comment'') ', 'an individual submission lists once with its field counts and stored grade')
; SELECT set_eq('
        SELECT (e ->> ''id'')::int
        FROM api.my_assignments, jsonb_array_elements(submissions) e
        WHERE slug = ''team-selection''
    ', ARRAY[1], 'a student sees only their own submission on team-selection, even selecting submissions alone')
; SELECT results_eq('
        SELECT extension_closed_at IS NULL AS no_extension,
               jsonb_array_length(submissions) AS n,
               (submissions -> 0 ->> ''id'')::int AS id,
               submissions -> 0 ->> ''team_nickname'' AS team_nickname,
               (submissions -> 0 ->> ''fields_submitted'')::int AS fields_submitted,
               (submissions -> 0 ->> ''fields_total'')::int AS fields_total,
               (submissions -> 0 -> ''grade'' ->> ''points'')::real AS points
        FROM api.my_assignments
        WHERE slug = ''project-update-1''
    ', ' VALUES (true, 1, 4, ''bright-fog'', 2, 2, 75::real) ', 'a team submission resolves through the participant snapshot, once, and another team''s exception stays invisible')
; SELECT results_eq('
        SELECT submissions
        FROM api.my_assignments
        WHERE slug = ''exam-1''
    ', ' VALUES (''[]''::jsonb) ', 'submissions is [] rather than NULL when there are none')
;
--
-- Exception later than the deadline: the extension applies.
--
SELECT results_eq('
        SELECT is_open,
               closed_at < current_timestamp AS deadline_passed,
               effective_closed_at = extension_closed_at AS extension_applies,
               effective_closed_at > current_timestamp AS still_open_for_me,
               submission_window_open, can_submit, can_submit_reason,
               extension_fractional_credit
        FROM api.my_assignments
        WHERE slug = ''zz-my-past''
    ', ' VALUES (false, true, true, true, true, true, NULL::text, 0.8::numeric) ', 'an extension past a closed deadline reopens the window while is_open stays false')
;
--
-- Exception earlier than the deadline: greatest wins. An expired exception
-- must not close an open assignment.
--
SELECT results_eq('
        SELECT effective_closed_at = closed_at AS deadline_stands,
               extension_closed_at < current_timestamp AS extension_expired,
               submission_window_open, can_submit, can_submit_reason,
               extension_fractional_credit
        FROM api.my_assignments
        WHERE slug = ''zz-my-open''
    ', ' VALUES (true, true, true, true, NULL::text, 0.5::numeric) ', 'an expired exception is surfaced but does not close an open assignment')
;
--
-- Draft: evaluated before the deadline, so a live exception does not help.
--
SELECT results_eq('
        SELECT is_draft, submission_window_open, can_submit, can_submit_reason,
               extension_closed_at IS NOT NULL AS has_extension
        FROM api.my_assignments
        WHERE slug = ''zz-my-draft''
    ', ' VALUES (true, false, false, ''draft'', true) ', 'a draft reports reason draft even with a live exception')
;
--
-- can_submit agrees with the write policy, positive direction: both of the
-- "true" cases above accept a submission.
--
SELECT request.reset_row_bound_counters()
; SELECT lives_ok('
        INSERT INTO api.assignment_submissions (assignment_slug)
        VALUES (''zz-my-past'')
    ', 'can_submit true under an extension: the write policy accepts the submission')
; SELECT lives_ok('
        INSERT INTO api.assignment_submissions (assignment_slug)
        VALUES (''zz-my-open'')
    ', 'can_submit true under an expired exception: the write policy accepts the submission')
;
--
-- An empty parent submission is not "submitted", and neither is an empty
-- field; a field with a body is.
--
SELECT results_eq('
        SELECT (submissions -> 0 ->> ''fields_submitted'')::int AS fields_submitted,
               (submissions -> 0 ->> ''fields_total'')::int AS fields_total,
               submissions -> 0 -> ''grade'' AS grade
        FROM api.my_assignments
        WHERE slug = ''zz-my-past''
    ', ' VALUES (0, 1, ''null''::jsonb) ', 'a parent submission with no fields counts zero submitted and a null grade')
; SELECT lives_ok('
        INSERT INTO api.assignment_field_submissions (assignment_submission_id, assignment_field_slug, body)
        SELECT id, ''url'', ''''
        FROM api.assignment_submissions
        WHERE assignment_slug = ''zz-my-past''
    ', 'a field submission with an empty body can be created')
; SELECT
    "is"((
        SELECT ((submissions -> 0) ->> 'fields_submitted')::int
        FROM api.my_assignments
        WHERE slug = 'zz-my-past'
    ), 0, 'an empty field body does not count as submitted')
; UPDATE api.assignment_field_submissions
SET body = 'done'
WHERE assignment_slug = 'zz-my-past'
; SELECT
    "is"((
        SELECT ((submissions -> 0) ->> 'fields_submitted')::int
        FROM api.my_assignments
        WHERE slug = 'zz-my-past'
    ), 1, 'a field with a body counts as submitted')
;
--
-- Negative direction, as user 2, who holds none of user 1''s exceptions.
--
SELECT request.reset_row_bound_counters()
; SET "request.jwt.claim.user_id" TO "2"
; SELECT results_eq('
        SELECT effective_closed_at = closed_at AS deadline_stands,
               extension_closed_at IS NULL AS no_extension,
               submission_window_open, can_submit, can_submit_reason
        FROM api.my_assignments
        WHERE slug = ''zz-my-past''
    ', ' VALUES (true, true, false, false, ''deadline_passed'') ', 'another student''s exception is invisible and the deadline stands')
; SELECT throws_like('
        INSERT INTO api.assignment_submissions (assignment_slug)
        VALUES (''zz-my-past'')
    ', '%row-level security%', 'can_submit false past the deadline: the write policy refuses the submission')
; SELECT throws_like('
        INSERT INTO api.assignment_submissions (assignment_slug)
        VALUES (''zz-my-draft'')
    ', '%row-level security%', 'can_submit false on a draft: the write policy refuses the submission')
; SELECT set_eq('
        SELECT (e ->> ''id'')::int
        FROM api.my_assignments, jsonb_array_elements(submissions) e
        WHERE slug = ''team-selection''
    ', ARRAY[2], 'user 2 sees only their own submission on team-selection')
;
--
-- Team assignment with no team: user 4 (ta) is on none.
--
SET "request.jwt.claim.user_id" TO "4"
; SELECT results_eq('
        SELECT submission_window_open, can_submit, can_submit_reason, submissions
        FROM api.my_assignments
        WHERE slug = ''project-update-1''
    ', ' VALUES (true, false, ''no_team'', ''[]''::jsonb) ', 'a team assignment reports no_team for a caller on no team')
;
--
-- Team move: user 2 submits with hazy-mountain, moves to damp-pond, and the
-- new team submits again. Both submissions are theirs, newest first, each
-- with its own grade; the extension follows the CURRENT team.
--
-- Back to the migrator to build the fixture; student has no rights on data.*.
RESET role
; INSERT INTO data.assignment_submission (assignment_slug, is_team, team_nickname, submitter_user_id, created_at)
VALUES ('project-update-1', true, 'hazy-mountain', 2, current_timestamp - '2 days'::interval)
; INSERT INTO data.assignment_grade (assignment_submission_id, points, description)
SELECT id, 70, 'first team'
FROM data.assignment_submission
WHERE
    team_nickname = 'hazy-mountain'
    AND assignment_slug = 'project-update-1'
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "2"
; SELECT results_eq('
        SELECT extension_closed_at,
               jsonb_array_length(submissions) AS n,
               submissions -> 0 ->> ''team_nickname'' AS team_nickname
        FROM api.my_assignments
        WHERE slug = ''project-update-1''
    ', '
        SELECT closed_at AS extension_closed_at, 1 AS n, ''hazy-mountain''::text AS team_nickname
        FROM api.assignment_grade_exceptions
        WHERE team_nickname = ''hazy-mountain'' AND assignment_slug = ''project-update-1''
    ', 'before the move the team''s exception and one submission are the caller''s')
; RESET role
; UPDATE data."user"
SET team_nickname = 'damp-pond'
WHERE id = 2
; INSERT INTO data.assignment_submission (assignment_slug, is_team, team_nickname, submitter_user_id, created_at)
VALUES ('project-update-1', true, 'damp-pond', 2, current_timestamp - '1 day'::interval)
; INSERT INTO data.assignment_grade (assignment_submission_id, points, description)
SELECT id, 60, 'second team'
FROM data.assignment_submission
WHERE
    team_nickname = 'damp-pond'
    AND assignment_slug = 'project-update-1'
;
-- Stash what the view should list, while data.* is still readable.
CREATE TEMPORARY TABLE zz_team_subs AS
    SELECT s.id, s.team_nickname, s.created_at, g.points, g.description
    FROM
        data.assignment_submission s
        JOIN data.assignment_grade g ON g.assignment_submission_id = s.id
    WHERE
        s.assignment_slug = 'project-update-1'
        AND s.team_nickname IN ('hazy-mountain', 'damp-pond')
; GRANT select ON zz_team_subs TO student
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "2"
; SELECT
    "is"((
        SELECT jsonb_array_length(submissions)
        FROM api.my_assignments
        WHERE slug = 'project-update-1'
    ), 2, 'a student who changed teams holds both submissions on the assignment')
; SELECT results_eq('
        SELECT (e ->> ''id'')::int AS id,
               e ->> ''team_nickname'' AS team_nickname,
               (e -> ''grade'' ->> ''points'')::real AS points,
               e -> ''grade'' ->> ''description'' AS description
        FROM api.my_assignments, jsonb_array_elements(submissions) WITH ORDINALITY AS x (e, ord)
        WHERE slug = ''project-update-1''
        ORDER BY ord
    ', '
        SELECT id, team_nickname, points, description
        FROM zz_team_subs
        ORDER BY created_at DESC, id DESC
    ', 'submissions are newest first, each carrying its own grade by submission id')
; SELECT
    "is"((
        SELECT extension_closed_at
        FROM api.my_assignments
        WHERE slug = 'project-update-1'
    ), NULL::timestamptz, 'the extension resolves through the current team, which has none')
; SELECT
    "is"((
        SELECT can_submit_reason
        FROM api.my_assignments
        WHERE slug = 'project-update-1'
    ), NULL::text, 'and the caller is still eligible: on a team, before the deadline')
;
--
-- Faculty: RLS admits every row to them, but the view is still theirs.
-- User 3 owns submission 3 on team-selection and sits on bright-fog.
--
SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT set_eq('
        SELECT (e ->> ''id'')::int
        FROM api.my_assignments, jsonb_array_elements(submissions) e
        WHERE slug = ''team-selection''
    ', ARRAY[3], 'faculty see only their own submission, not every student''s')
; SELECT
    "is"((
        SELECT extension_closed_at
        FROM api.my_assignments
        WHERE slug = 'team-selection'
    ), NULL::timestamptz, 'faculty do not see a student''s exception as their own')
; SELECT *
FROM finish()
