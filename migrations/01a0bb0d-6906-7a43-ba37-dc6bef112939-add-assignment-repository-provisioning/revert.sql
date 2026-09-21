-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- What is lost. Dropping data.assignment_repository_provisioning drops every
-- attempt: which students clicked, how far each attempt got, and the error
-- codes of the ones that failed. Dropping the three template columns loses
-- every assignment's repository configuration, and dropping the three GitHub
-- columns loses every linked or imported GitHub identity, verified or not.
-- None of that is reconstructible from elsewhere in this database. What is
-- NOT lost: data.assignment_repository rows, assignment submissions and the
-- field submissions finalize wrote, with their origin of 'provisioning'.
-- Those are ordinary course records and stay. Revert after real provisioning
-- has run only with a dump of the three tables in hand.
--
-- The api views cannot lose a column through CREATE OR REPLACE, and
-- api.assignments and api.users are named inside row policies of other
-- tables and inside api.my_assignments, so those dependents are dropped and
-- recreated exactly as the bootstrap and 01a08afb defined them.
DROP FUNCTION IF EXISTS api.import_github_logins(text, text)
; DROP FUNCTION IF EXISTS api.set_user_github_identity(int, bigint, text, boolean)
; DROP FUNCTION IF EXISTS api.touch_repository_provisioning_readiness(int, boolean)
; DROP FUNCTION IF EXISTS api.finalize_repository_provisioning(int, text, bigint)
; DROP FUNCTION IF EXISTS api.record_repository_provisioning(int, text, bigint, text, text)
; DROP FUNCTION IF EXISTS api.claim_repository_provisioning(text, int)
; DROP VIEW IF EXISTS api.assignment_repository_provisionings
; DROP TABLE IF EXISTS data.assignment_repository_provisioning
; DROP POLICY IF EXISTS assignment_submission_access_policy ON data.assignment_submission
; DROP POLICY IF EXISTS assignment_grade_exception_access_policy ON data.assignment_grade_exception
; DROP POLICY IF EXISTS team_access_policy ON data.team
; DROP POLICY IF EXISTS user_secret_access_policy ON data.user_secret
; DROP VIEW IF EXISTS api.my_assignments
; DROP VIEW IF EXISTS api.assignments
; DROP VIEW IF EXISTS api.users
; DROP TRIGGER IF EXISTS tg_assignment_field_designated_url ON data.assignment_field
; DROP FUNCTION IF EXISTS data.keep_designated_repository_url_field()
; DROP TRIGGER IF EXISTS tg_assignment_repository_url_field ON data.assignment
; DROP FUNCTION IF EXISTS data.check_assignment_repository_url_field()
; ALTER TABLE data.assignment
    DROP repository_template_provider,
    DROP repository_template_full_name,
    DROP repository_url_field_slug
; ALTER TABLE data."user"
    DROP github_user_id,
    DROP github_login,
    DROP github_verified_at
;
-- api.assignments as 01a05f88 left it.
CREATE VIEW api.assignments WITH (security_barrier=true) AS
    SELECT
        slug, points_possible, is_draft, is_markdown, is_team, title, body,
        closed_at, created_at, updated_at, is_draft = false
        AND current_timestamp < closed_at AS is_open
    FROM data.assignment
; ALTER VIEW api.assignments
    OWNER TO api
; GRANT select ON api.assignments TO student, ta
; GRANT select, insert, update, delete ON api.assignments TO faculty
; COMMENT ON VIEW api.assignments IS 'Assignments that students can view or submit, with draft rows reserved for faculty'
; COMMENT ON COLUMN api.assignments.slug IS 'Short identifier for the assignment'
; COMMENT ON COLUMN api.assignments.points_possible IS 'Maximum score for the assignment'
; COMMENT ON COLUMN api.assignments.is_draft IS 'Whether the assignment is still hidden from students and TAs'
; COMMENT ON COLUMN api.assignments.is_markdown IS 'Whether the assignment body should be rendered as Markdown'
; COMMENT ON COLUMN api.assignments.is_team IS 'Whether submissions are made by teams instead of individuals'
; COMMENT ON COLUMN api.assignments.title IS 'Human-readable assignment title'
; COMMENT ON COLUMN api.assignments.body IS 'Assignment instructions or content'
; COMMENT ON COLUMN api.assignments.closed_at IS 'Deadline after which normal submissions are closed'
; COMMENT ON COLUMN api.assignments.created_at IS 'When this assignment row was created'
; COMMENT ON COLUMN api.assignments.updated_at IS 'When this assignment row was last updated'
; COMMENT ON COLUMN api.assignments.is_open IS 'Whether the assignment is published and still open for normal submission'
;
-- api.users as the bootstrap defined it, with faculty's table-wide write
-- privileges back in place of the column list.
CREATE VIEW api.users AS
    SELECT
        id, email, netid, name, lastname, organization, known_as, nickname,
        role, created_at, updated_at, team_nickname
    FROM data."user"
; ALTER VIEW api.users
    OWNER TO api
; GRANT select ON api.users TO student, ta, app
; GRANT select, insert, delete, update ON api.users TO faculty
; COMMENT ON VIEW api.users IS 'Course users and their public course metadata'
; COMMENT ON COLUMN api.users.id IS 'Unique user id'
; COMMENT ON COLUMN api.users.email IS 'User email address'
; COMMENT ON COLUMN api.users.netid IS 'University netid for the user'
; COMMENT ON COLUMN api.users.name IS 'Given name for the user'
; COMMENT ON COLUMN api.users.lastname IS 'Family name for the user'
; COMMENT ON COLUMN api.users.organization IS 'Organization or school associated with the user'
; COMMENT ON COLUMN api.users.known_as IS 'Preferred display name for the user'
; COMMENT ON COLUMN api.users.nickname IS 'Pseudonymous nickname used in class-facing displays'
; COMMENT ON COLUMN api.users.role IS 'Course role assigned to the user'
; COMMENT ON COLUMN api.users.created_at IS 'When this user row was created'
; COMMENT ON COLUMN api.users.updated_at IS 'When this user row was last updated'
; COMMENT ON COLUMN api.users.team_nickname IS 'Team nickname assigned to the user, if any'
;
-- api.my_assignments as 01a08afb defined it.
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
; GRANT select ON api.my_assignments TO student, ta, faculty
; COMMENT ON VIEW api.my_assignments IS 'One row per assignment for the calling user: the deadline that applies to them, whether they can submit right now and why not, their extension if any, and their own submissions with grades. Read-only. Body and fields are on assignments and assignment_fields'
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
;
-- The four row policies that name api.users or api.assignments, as the
-- bootstrap defined them.
CREATE POLICY assignment_submission_access_policy ON data.assignment_submission TO api USING ((request.user_role() = ANY('{student,ta}'::text[])
AND ((NOT is_team
AND request.user_id() = user_id) OR (is_team
AND ((request.user_id() = submitter_user_id
AND NOT EXISTS (
    SELECT 1
    FROM data.assignment_submission_participant p
    WHERE p.assignment_submission_id = assignment_submission.id
)) OR EXISTS (
    SELECT p.user_id
    FROM data.assignment_submission_participant p
    WHERE
        p.assignment_submission_id = assignment_submission.id
        AND p.user_id = request.user_id()
))))) OR request.user_role() = 'faculty'::text) WITH CHECK (request.user_role() = 'faculty'::text OR (request.user_role() = ANY('{student,ta}'::text[])
AND EXISTS (
    SELECT a.slug
    FROM
        api.assignments a
        LEFT JOIN api.assignment_grade_exceptions e ON a.slug = e.assignment_slug
        LEFT JOIN api.users u ON e.user_id = u.id OR e.team_nickname = u.team_nickname
    WHERE
        a.slug = assignment_submission.assignment_slug
        AND (a.is_open OR (e.closed_at > current_timestamp
        AND a.is_draft = false
        AND (e.user_id = assignment_submission.user_id OR e.team_nickname = assignment_submission.team_nickname)))
)
AND ((NOT is_team
AND request.user_id() = user_id) OR (is_team
AND EXISTS (
    SELECT u.id
    FROM data."user" u
    WHERE
        u.id = request.user_id()
        AND u.team_nickname = assignment_submission.team_nickname
)))))
; CREATE POLICY assignment_grade_exception_access_policy ON data.assignment_grade_exception TO api USING ((request.user_role() = ANY('{student,ta}'::text[])
AND ((NOT is_team
AND request.user_id() = user_id) OR (is_team
AND EXISTS (
    SELECT u.id
    FROM api.users u
    WHERE
        u.id = request.user_id()
        AND u.team_nickname = assignment_grade_exception.team_nickname
)))) OR request.user_role() = 'faculty'::text) WITH CHECK (request.user_role() = 'faculty'::text)
; CREATE POLICY team_access_policy ON data.team TO api USING ((request.user_role() = ANY('{student,ta}'::text[])
AND nickname = (
    SELECT users.team_nickname
    FROM api.users
    WHERE users.id = request.user_id()
)) OR request.user_role() = 'faculty'::text)
; CREATE POLICY user_secret_access_policy ON data.user_secret TO api USING ((request.user_role() = ANY('{student,ta}'::text[])
AND is_user_visible
AND (request.user_id() = user_id OR EXISTS (
    SELECT u.id
    FROM api.users u
    WHERE
        u.id = request.user_id()
        AND u.team_nickname = user_secret.team_nickname
))) OR request.user_role() = 'faculty'::text) WITH CHECK (request.user_role() = 'faculty'::text)
;
-- Back to the shape and RPC set that predate this migration.
CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::int AS platform_compatibility_version,
        7::int AS schema_compatibility_version, 14::int AS admin_api_version
; ALTER VIEW api.platform_version
    OWNER TO api
;
-- PostgREST would otherwise keep serving the dropped view and RPCs from its
-- cache, turning clean 404s into database errors.
NOTIFY pgrst, 'reload schema'
