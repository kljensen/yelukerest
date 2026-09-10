-- api.my_assignments: one me-scoped row per assignment (issue #380).
--
-- api.assignments computes is_open from the assignment's own closed_at, so a
-- student holding a grade exception that moved their deadline is told the
-- assignment is closed, although the write policies would accept their work.
-- The web client papers over this with its own join against
-- api.assignment_grade_exceptions; the API, and the MCP tools on it, do not.
-- More broadly, "due when for me, can I submit, have I, what did I get" took
-- four or five requests stitched together by the caller.
--
-- This view answers those questions in one row per assignment, for the caller
-- only. It changes nothing about api.assignments or api.assignment_fields:
-- is_open and closed_at are copied through with their meaning intact, so a
-- client can switch reads without a field changing under it. Body and fields
-- stay on the existing views.
--
-- The rules the columns follow, each pinned in tests/db/yeluke-my-assignments.sql:
--
--   * effective_closed_at is greatest(closed_at, my exception's closed_at), not
--     the exception's date: an expired exception must not close an assignment
--     that is still open. This is the OR in
--     data.assignment_field_submission_is_writable_by_current_user().
--   * On a team assignment the extension resolves through the caller's CURRENT
--     team (api.users.team_nickname), exactly as the write helper does.
--   * Submissions resolve through the insert-time participant snapshot
--     (data.assignment_submission_participant) plus individual submissions
--     with user_id = request.user_id(). A student who changed teams can hold
--     more than one submission on one assignment; every one is listed, each
--     with its own grade, and none is picked arbitrarily.
--   * fields_submitted counts field submissions with a non-empty body; an
--     empty parent submission is not "submitted".
--   * Grade points are stored values, unmultiplied. fractional_credit is
--     surfaced and never applied here.
--   * can_submit is coursework eligibility only: draft, deadline, team
--     membership, evaluated in that order. Scope and validation still apply
--     on the write itself.
--   * Submissions are aggregated in a subselect, and neither join can
--     multiply rows: `me` is one row or none (a caller on no team, or with no
--     user row, gets a NULL team), and `ge` is at most one row because the
--     partial unique indexes on data.assignment_grade_exception allow one
--     exception per (assignment, user) and one per (assignment, team).
--
-- Every personal join carries an explicit request.user_id() predicate. RLS on
-- the data tables would filter a student anyway, but it admits every row to
-- faculty, and a faculty member's "my assignments" should still be theirs.
CREATE VIEW api.my_assignments WITH (security_barrier=true) AS
    SELECT
        slug, title, is_team, is_draft, is_markdown, points_possible, is_open,
        closed_at, created_at, updated_at, effective_closed_at, NOT is_draft
        AND current_timestamp < effective_closed_at AS submission_window_open,
        can_submit_reason IS NULL AS can_submit, can_submit_reason,
        extension_closed_at, extension_fractional_credit, submissions
    FROM
        (
            SELECT
                a.slug, a.title, a.is_team, a.is_draft, a.is_markdown,
                a.points_possible, a.is_open, a.closed_at, a.created_at,
                a.updated_at,
                GREATEST(a.closed_at, ge.closed_at) AS effective_closed_at,
                CASE
                    WHEN a.is_draft THEN 'draft'
                    WHEN current_timestamp >= GREATEST(a.closed_at, ge.closed_at) THEN 'deadline_passed'
                    WHEN
                        a.is_team
                        AND me.team_nickname IS NULL THEN 'no_team'
                END AS can_submit_reason,
                ge.closed_at AS extension_closed_at,
                ge.fractional_credit AS extension_fractional_credit,
                (
                    SELECT
                        COALESCE(jsonb_agg(jsonb_build_object('id', s.id, 'team_nickname', s.team_nickname, 'created_at', s.created_at, 'updated_at', s.updated_at, 'fields_submitted', (
                            SELECT count(*)
                            FROM data.assignment_field_submission fs
                            WHERE
                                fs.assignment_submission_id = s.id
                                AND fs.body <> ''
                        ), 'fields_total', (
                            SELECT count(*)
                            FROM data.assignment_field af
                            WHERE af.assignment_slug = a.slug
                        ), 'grade', (
                            SELECT jsonb_build_object('points', g.points, 'description', g.description, 'created_at', g.created_at)
                            FROM data.assignment_grade g
                            WHERE g.assignment_submission_id = s.id
                        )) ORDER BY s.created_at DESC, s.id DESC), '[]'::jsonb)
                    FROM data.assignment_submission s
                    WHERE
                        s.assignment_slug = a.slug
                        AND (s.user_id = request.user_id() OR EXISTS (
                            SELECT 1
                            FROM data.assignment_submission_participant p
                            WHERE
                                p.assignment_submission_id = s.id
                                AND p.user_id = request.user_id()
                        ))
                ) AS submissions
            FROM
                api.assignments a
                LEFT JOIN api.users me ON me.id = request.user_id()
                LEFT JOIN data.assignment_grade_exception ge ON ge.assignment_slug = a.slug
                AND ((NOT a.is_team
                AND ge.user_id = request.user_id()) OR (a.is_team
                AND ge.team_nickname = me.team_nickname))
        ) mine
; ALTER VIEW api.my_assignments
    OWNER TO api
;
-- PostgREST surfaces these in OpenAPI, which get_api_schema serves to agents,
-- and tests/db/structure.sql requires every api view and column to carry one.
COMMENT ON VIEW api.my_assignments IS 'One row per assignment for the calling user: the deadline that applies to them, whether they can submit right now and why not, their extension if any, and their own submissions with grades. Read-only. Body and fields are on assignments and assignment_fields'
; COMMENT ON COLUMN api.my_assignments.slug IS 'Assignment slug, the key into assignments and assignment_fields'
; COMMENT ON COLUMN api.my_assignments.title IS 'Assignment title'
; COMMENT ON COLUMN api.my_assignments.is_team IS 'Whether submissions are made by a team rather than an individual'
; COMMENT ON COLUMN api.my_assignments.is_draft IS 'Whether the assignment is still a draft. Drafts are listed, labelled, and never submittable'
; COMMENT ON COLUMN api.my_assignments.is_markdown IS 'Whether the assignment body is Markdown'
; COMMENT ON COLUMN api.my_assignments.points_possible IS 'Maximum points for the assignment'
; COMMENT ON COLUMN api.my_assignments.is_open IS 'Same value and meaning as assignments.is_open: published and before the assignment''s own closed_at. Ignores extensions; use can_submit for eligibility'
; COMMENT ON COLUMN api.my_assignments.closed_at IS 'The assignment''s own deadline, same as assignments.closed_at. Ignores extensions; see effective_closed_at'
; COMMENT ON COLUMN api.my_assignments.created_at IS 'When the assignment was created, same as assignments.created_at'
; COMMENT ON COLUMN api.my_assignments.updated_at IS 'When the assignment was last updated, same as assignments.updated_at'
; COMMENT ON COLUMN api.my_assignments.effective_closed_at IS 'The deadline that applies to the calling user: the later of closed_at and their extension''s closed_at, if they have one'
; COMMENT ON COLUMN api.my_assignments.submission_window_open IS 'Not a draft and now is before effective_closed_at'
; COMMENT ON COLUMN api.my_assignments.can_submit IS 'Whether the calling user is eligible to submit right now: not a draft, before effective_closed_at, and on a team if the assignment is a team assignment. Token scope and field validation still apply on the write'
; COMMENT ON COLUMN api.my_assignments.can_submit_reason IS 'Why can_submit is false: draft, deadline_passed or no_team, evaluated in that order. NULL when can_submit is true'
; COMMENT ON COLUMN api.my_assignments.extension_closed_at IS 'closed_at of the calling user''s grade exception on this assignment, resolved through their current team on a team assignment. NULL when they have none. May be earlier than closed_at, in which case it does not apply'
; COMMENT ON COLUMN api.my_assignments.extension_fractional_credit IS 'fractional_credit of the calling user''s grade exception, between 0 and 1. NULL when they have none. Never applied to points here'
; COMMENT ON COLUMN api.my_assignments.submissions IS 'The calling user''s submissions on this assignment, newest first, [] when none: [{id, team_nickname, created_at, updated_at, fields_submitted, fields_total, grade: null | {points, description, created_at}}]. fields_submitted counts fields with a non-empty body. A student who changed teams can have more than one'
; GRANT select ON api.my_assignments TO student, ta, faculty
;
-- PostgREST caches the schema; without this it keeps serving without the view.
NOTIFY pgrst, 'reload schema'
