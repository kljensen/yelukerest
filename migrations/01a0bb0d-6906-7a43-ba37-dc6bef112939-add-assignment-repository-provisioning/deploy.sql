-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.
-- Self-serve assignment repositories: template configuration, GitHub identity,
-- and the provisioning attempt with its service RPCs (issue #394).
--
-- data.assignment_repository (01a011e3) records a repository once the forge
-- has returned its id. It cannot say which template an assignment is built
-- from, which field the repository URL is handed in through, or that an
-- attempt is under way and where it got to. `admin provision-repos` kept all
-- of that in a course repo and its own memory, and wrote the student's URL
-- field with a direct connection. This migration moves the configuration,
-- the attempt and the finalizing transaction into the database, where the
-- deadline, the team roster, the submission and the RLS already are.
-- authapp (#395, #396) drives the forge and calls the RPCs below; it holds
-- no course data of its own.
--
-- Three additions, in order:
--   * data.assignment gains an optional template configuration: the forge,
--     the template repository and the URL field the finished repository is
--     submitted through. All three or none, so an unconfigured assignment
--     behaves exactly as before.
--   * data."user" gains the student's GitHub identity: the numeric account
--     id (identity), the login (display, and the repository name), and when
--     the platform verified the link. Phase one fills the login from a
--     faculty import with verified_at NULL; phase two (#399) verifies.
--   * data.assignment_repository_provisioning is the attempt: claimed by the
--     student's click, advanced by authapp as the forge answers, finalized
--     into a repository row, a submission and a field submission in one
--     transaction. One attempt per owner per assignment, like the repository.
--
-- The RPCs are SECURITY DEFINER, owned by yelukerest_migrator like
-- api.exchange_user_api_token, and admit only the authapp service credential
-- (role app, app_name authapp), except api.import_github_logins which is the
-- faculty bootstrap. The guards compare with IS DISTINCT FROM: a session with
-- no role or no app_name claim at all must be refused, and `NOT (NULL AND x)`
-- is NULL, which an IF treats as false. Every refusal a client should branch on is raised with
-- a stable code as the MESSAGE and the explanation in DETAIL, so authapp maps
-- the message and never parses prose.
-- ---------------------------------------------------------------------------
-- data.assignment: the template configuration
-- ---------------------------------------------------------------------------
-- provider is constrained to the same slug shape as
-- assignment_repository.provider, so the two never disagree on what to call
-- a forge. template_full_name is owner/repo: a GitHub owner is a login (no
-- leading, trailing or doubled hyphen), and a repository name is a dotted
-- token. repository_url_field_slug names the assignment's own field; the
-- foreign key below is what makes a field of another assignment
-- unrepresentable, and its default NO ACTION is what stops a designated
-- field being deleted from under the configuration.
ALTER TABLE data.assignment
    ADD COLUMN repository_template_provider text CHECK (repository_template_provider ~ '^[a-z][a-z0-9_-]{0,31}$'),
    ADD COLUMN repository_template_full_name text CHECK (repository_template_full_name ~ '^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}/[A-Za-z0-9._-]+$'
    AND char_length(repository_template_full_name) BETWEEN 3 AND 255),
    ADD COLUMN repository_url_field_slug text CHECK (char_length(repository_url_field_slug) < 30),
    ADD CONSTRAINT repository_template_all_or_nothing CHECK ((repository_template_provider IS NULL) = (repository_template_full_name IS NULL)
    AND (repository_template_provider IS NULL) = (repository_url_field_slug IS NULL)),
    ADD CONSTRAINT assignment_repository_url_field_fkey FOREIGN KEY (slug, repository_url_field_slug) REFERENCES data.assignment_field (assignment_slug, slug)
;
-- tests/db/foreign-key-indexes.sql requires a plain btree index on every
-- data foreign key's referencing columns, in the constraint's column order.
-- The primary key on slug alone does not cover a two-column key.
CREATE INDEX idx_assignment_repository_url_field_fk
ON data.assignment USING btree (slug, repository_url_field_slug)
; COMMENT ON COLUMN data.assignment.repository_template_provider IS 'Forge the template repository lives on, such as github. Set with the other two template columns or not at all. Issue #394.'
; COMMENT ON COLUMN data.assignment.repository_template_full_name IS 'Template repository as owner/repo on the provider. Issue #394.'
; COMMENT ON COLUMN data.assignment.repository_url_field_slug IS 'The URL field of this assignment that a provisioned repository is submitted through. Must be is_url. Issue #394.'
;
-- The designated field has to be a URL field. A foreign key can say the field
-- exists but not what kind it is, so two triggers hold that line: one on the
-- assignment when the configuration is set, and one on the field so is_url
-- cannot be switched off while an assignment points at it. The first says
-- only what the foreign key cannot: a field that does not exist is left to
-- the foreign key, so that refusal reads as the missing reference it is. Both
-- run as the definer because faculty write through api views and hold
-- nothing on the data schema, as the existing lookup triggers do.
--
-- Each locks the row it reads FOR UPDATE before deciding, so two sessions --
-- one designating the field, one flipping its is_url -- serialize on the
-- field row instead of both passing a check against a snapshot and
-- committing a designated non-URL field.
CREATE FUNCTION data.check_assignment_repository_url_field() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO data, pg_temp AS $$
DECLARE
    field_is_url boolean;
BEGIN
    IF NEW.repository_url_field_slug IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT f.is_url INTO field_is_url
    FROM data.assignment_field f
    WHERE f.assignment_slug = NEW.slug
      AND f.slug = NEW.repository_url_field_slug
    FOR UPDATE;
    IF field_is_url IS FALSE THEN
        RAISE EXCEPTION 'repository_url_field_slug must name a URL field of this assignment'
            USING ERRCODE = '23514',
                  DETAIL = format('assignment %s field %s is not is_url', NEW.slug, NEW.repository_url_field_slug);
    END IF;
    RETURN NEW;
END;
$$
; ALTER FUNCTION data.check_assignment_repository_url_field() OWNER TO yelukerest_migrator
; CREATE TRIGGER tg_assignment_repository_url_field BEFORE INSERT OR UPDATE OF repository_url_field_slug ON data.assignment FOR EACH ROW EXECUTE FUNCTION data.check_assignment_repository_url_field()
; CREATE FUNCTION data.keep_designated_repository_url_field_is_url() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO data, pg_temp AS $$
BEGIN
    IF NOT NEW.is_url AND EXISTS (
        SELECT 1
        FROM data.assignment a
        WHERE a.slug = NEW.assignment_slug
          AND a.repository_url_field_slug = NEW.slug
        FOR UPDATE
    ) THEN
        RAISE EXCEPTION 'this field is the repository URL field of its assignment and must stay is_url'
            USING ERRCODE = '23514',
                  DETAIL = format('assignment %s designates field %s as repository_url_field_slug', NEW.assignment_slug, NEW.slug),
                  HINT = 'Clear the assignment''s template configuration first.';
    END IF;
    RETURN NEW;
END;
$$
; ALTER FUNCTION data.keep_designated_repository_url_field_is_url() OWNER TO yelukerest_migrator
; CREATE TRIGGER tg_assignment_field_designated_url BEFORE UPDATE OF is_url ON data.assignment_field FOR EACH ROW EXECUTE FUNCTION data.keep_designated_repository_url_field_is_url()
;
-- ---------------------------------------------------------------------------
-- data."user": GitHub identity
-- ---------------------------------------------------------------------------
-- The numeric id is identity, as assignment_repository.provider_user_id is:
-- it survives a login rename. One account per person, hence the partial
-- unique index. The login is what the repository is named after, and is
-- constrained to GitHub's own shape. verified_at is NULL for an identity a
-- faculty member attested (api.import_github_logins) and set only by the
-- service once the student has proven the account (#399); a public lookup
-- of the login never sets it.
ALTER TABLE data."user"
    ADD COLUMN github_user_id bigint CHECK (github_user_id > 0),
    ADD COLUMN github_login text CHECK (github_login ~ '^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$'),
    ADD COLUMN github_verified_at timestamp with time zone
; CREATE UNIQUE INDEX user_unique_github_user_id
ON data."user" USING btree (github_user_id)
WHERE github_user_id IS NOT NULL
;
-- One login per person too, case-insensitively: GitHub logins are
-- case-insensitive, and the repository name derives from the login, so two
-- users sharing one would collide on the forge as well as here.
CREATE UNIQUE INDEX user_unique_github_login
ON data."user" USING btree (lower(github_login))
WHERE github_login IS NOT NULL
; COMMENT ON COLUMN data."user".github_user_id IS 'GitHub account id. Identity: survives a login rename. Written only by api.set_user_github_identity. Issue #394.'
; COMMENT ON COLUMN data."user".github_login IS 'GitHub login. Names the student''s provisioned repositories. Written by api.set_user_github_identity or the faculty bootstrap api.import_github_logins. Issue #394.'
; COMMENT ON COLUMN data."user".github_verified_at IS 'When the platform verified this GitHub identity belongs to the user. NULL for a faculty-attested import. Issue #394.'
;
-- ---------------------------------------------------------------------------
-- data.assignment_repository_provisioning: the attempt
-- ---------------------------------------------------------------------------
-- Shaped after data.assignment_repository: the same (slug, is_team) foreign
-- key, the same user XOR team check, the same one-per-owner partial unique
-- indexes. What it adds is the state of an attempt: the template and
-- destination name as they were when the student clicked, the forge id once
-- generate has returned it, the stage, and a sanitized error code. No lease:
-- an attempt that is not finalized is simply resumed by the next request.
--
-- provider_repo_id is NOT unique here on purpose. A failed attempt may hold
-- the id of a repository that was generated and then lost, and a later
-- attempt for another owner must not be refused by it; uniqueness belongs to
-- data.assignment_repository, which finalize writes.
CREATE TABLE data.assignment_repository_provisioning (
    id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    assignment_slug text NOT NULL CHECK (char_length(assignment_slug) < 100),
    is_team boolean NOT NULL,
    FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment (slug, is_team) ON UPDATE CASCADE,
    user_id int REFERENCES data."user" (id) ON UPDATE CASCADE,
    team_nickname text CHECK (char_length(team_nickname) < 50) REFERENCES data.team (nickname) ON UPDATE CASCADE,
    initiated_by_user_id int NOT NULL REFERENCES data."user" (id) ON UPDATE CASCADE,
    provider text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_-]{0,31}$'),
    template_full_name text NOT NULL CHECK (char_length(template_full_name) BETWEEN 3 AND 255),
    destination_name text NOT NULL CHECK (destination_name ~ '^[A-Za-z0-9._-]{1,100}$'),
    provider_repo_id bigint CHECK (provider_repo_id > 0),
    provider_full_name text CHECK (char_length(provider_full_name) BETWEEN 1 AND 255),
    stage text NOT NULL DEFAULT 'claimed' CHECK (stage IN ('claimed', 'generated', 'granted', 'finalized', 'failed')),
    error_code text CHECK (error_code ~ '^[a-z][a-z0-9_]{0,63}$'),
    last_checked_at timestamp with time zone,
    ready_at timestamp with time zone,
    created_at timestamp with time zone NOT NULL DEFAULT current_timestamp,
    updated_at timestamp with time zone NOT NULL DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    CONSTRAINT matches_assignment_is_team CHECK ((is_team
    AND team_nickname IS NOT NULL
    AND user_id IS NULL) OR (NOT is_team
    AND team_nickname IS NULL
    AND user_id IS NOT NULL)),
    CONSTRAINT generated_knows_repository CHECK (
    -- generate returned before granted or finalized could be recorded, so a
    -- row past 'generated' always knows its repository.
    stage IN ('claimed', 'failed') OR (provider_repo_id IS NOT NULL
    AND provider_full_name IS NOT NULL))
)
; ALTER TABLE data.assignment_repository_provisioning
    OWNER TO yelukerest_migrator
; CREATE UNIQUE INDEX assignment_repository_provisioning_unique_user
ON data.assignment_repository_provisioning USING btree (user_id, assignment_slug)
WHERE team_nickname IS NULL
; CREATE UNIQUE INDEX assignment_repository_provisioning_unique_team
ON data.assignment_repository_provisioning USING btree (team_nickname, assignment_slug)
WHERE user_id IS NULL
;
-- Foreign key indexes, as tests/db/foreign-key-indexes.sql requires.
CREATE INDEX idx_assignment_repository_provisioning_assignment_fk
ON data.assignment_repository_provisioning USING btree (assignment_slug, is_team)
; CREATE INDEX idx_assignment_repository_provisioning_user_fk
ON data.assignment_repository_provisioning USING btree (user_id)
; CREATE INDEX idx_assignment_repository_provisioning_team_fk
ON data.assignment_repository_provisioning USING btree (team_nickname)
; CREATE INDEX idx_assignment_repository_provisioning_initiator_fk
ON data.assignment_repository_provisioning USING btree (initiated_by_user_id)
; CREATE TRIGGER tg_assignment_repository_provisioning_update_timestamps BEFORE INSERT OR UPDATE ON data.assignment_repository_provisioning FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column()
; COMMENT ON TABLE data.assignment_repository_provisioning IS 'An attempt to provision a forge repository for a student or team on an assignment, from the click to the finalized repository row'
;
-- Read-only through the view. Nobody writes this table but the RPCs, which
-- run as the owner; the api role needs SELECT so the view can serve it, and
-- the policy keeps a student to their own attempts and their current team's,
-- as data.assignment_repository does.
GRANT select ON data.assignment_repository_provisioning TO api
; ALTER TABLE data.assignment_repository_provisioning
    ENABLE ROW LEVEL SECURITY
; CREATE POLICY assignment_repository_provisioning_access_policy ON data.assignment_repository_provisioning FOR SELECT TO api USING (request.user_role() = 'faculty' OR (request.user_role() = ANY('{student,ta}'::text[])
AND ((NOT is_team
AND request.user_id() = user_id) OR (is_team
AND EXISTS (
    SELECT 1
    FROM data."user" u
    WHERE
        u.id = request.user_id()
        AND u.team_nickname = assignment_repository_provisioning.team_nickname
)))))
; CREATE VIEW api.assignment_repository_provisionings AS
    SELECT *
    FROM data.assignment_repository_provisioning
; ALTER VIEW api.assignment_repository_provisionings
    OWNER TO api
; GRANT select ON api.assignment_repository_provisionings TO student, ta, faculty
; COMMENT ON VIEW api.assignment_repository_provisionings IS 'Repository provisioning attempts: one per student or team per assignment, with the stage the attempt has reached. Read-only; the authapp service advances it'
; COMMENT ON COLUMN api.assignment_repository_provisionings.id IS 'Surrogate key for this attempt'
; COMMENT ON COLUMN api.assignment_repository_provisionings.assignment_slug IS 'The assignment the repository is being provisioned for'
; COMMENT ON COLUMN api.assignment_repository_provisionings.is_team IS 'True when the repository will belong to a team, matching the assignment kind'
; COMMENT ON COLUMN api.assignment_repository_provisionings.user_id IS 'Owning student, set when the assignment is individual and NULL otherwise'
; COMMENT ON COLUMN api.assignment_repository_provisionings.team_nickname IS 'Owning team, set when the assignment is a team assignment and NULL otherwise'
; COMMENT ON COLUMN api.assignment_repository_provisionings.initiated_by_user_id IS 'The student who started the attempt; for a team, one of its members'
; COMMENT ON COLUMN api.assignment_repository_provisionings.provider IS 'Forge the repository is created on, copied from the assignment when the attempt was claimed'
; COMMENT ON COLUMN api.assignment_repository_provisionings.template_full_name IS 'Template repository as owner/repo, copied from the assignment when the attempt was claimed'
; COMMENT ON COLUMN api.assignment_repository_provisionings.destination_name IS 'Name of the repository to create, without its organization: assignment slug and GitHub login or team nickname'
; COMMENT ON COLUMN api.assignment_repository_provisionings.provider_repo_id IS 'Forge repository id, NULL until the forge has returned one'
; COMMENT ON COLUMN api.assignment_repository_provisionings.provider_full_name IS 'Forge repository name such as org/repo, NULL until the forge has returned one'
; COMMENT ON COLUMN api.assignment_repository_provisionings.stage IS 'How far the attempt has got: claimed, generated, granted, finalized or failed'
; COMMENT ON COLUMN api.assignment_repository_provisionings.error_code IS 'Stable code for why the attempt failed, NULL otherwise. Never a raw forge message'
; COMMENT ON COLUMN api.assignment_repository_provisionings.last_checked_at IS 'When the service last asked the forge whether the repository contents were ready'
; COMMENT ON COLUMN api.assignment_repository_provisionings.ready_at IS 'When the forge first reported the repository contents ready, NULL until then'
; COMMENT ON COLUMN api.assignment_repository_provisionings.created_at IS 'When the attempt was claimed'
; COMMENT ON COLUMN api.assignment_repository_provisionings.updated_at IS 'When the attempt last changed'
;
-- ---------------------------------------------------------------------------
-- The api views that carry the new columns
-- ---------------------------------------------------------------------------
-- api.assignments lists its columns, so the base table growing does not grow
-- the view; the three template columns are appended, which CREATE OR REPLACE
-- permits. Faculty already hold INSERT and UPDATE on the view, so they
-- configure a template with an ordinary PATCH; students hold SELECT only.
CREATE OR REPLACE VIEW api.assignments WITH (security_barrier=true) AS
    SELECT
        slug, points_possible, is_draft, is_markdown, is_team, title, body,
        closed_at, created_at, updated_at, is_draft = false
        AND current_timestamp < closed_at AS is_open,
        repository_template_provider, repository_template_full_name,
        repository_url_field_slug
    FROM data.assignment
; ALTER VIEW api.assignments
    OWNER TO api
; COMMENT ON COLUMN api.assignments.repository_template_provider IS 'Forge the template repository lives on, such as github; NULL when the assignment has no self-serve repository'
; COMMENT ON COLUMN api.assignments.repository_template_full_name IS 'Template repository as owner/repo that a student''s repository is generated from; NULL when not configured'
; COMMENT ON COLUMN api.assignments.repository_url_field_slug IS 'Slug of this assignment''s URL field that the provisioned repository is submitted through; NULL when not configured'
;
-- api.my_assignments, as 01a08afb defined it, with the same three columns
-- appended so a client reading the me-scoped row knows whether to offer the
-- repository button.
CREATE OR REPLACE VIEW api.my_assignments WITH (security_barrier=true) AS
    SELECT
        slug, title, is_team, is_draft, is_markdown, points_possible, is_open,
        closed_at, created_at, updated_at, effective_closed_at, NOT is_draft
        AND current_timestamp < effective_closed_at AS submission_window_open,
        can_submit_reason IS NULL AS can_submit, can_submit_reason,
        extension_closed_at, extension_fractional_credit, submissions,
        repository_template_provider, repository_template_full_name,
        repository_url_field_slug
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
                ) AS submissions,
                a.repository_template_provider, a.repository_template_full_name,
                a.repository_url_field_slug
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
; COMMENT ON COLUMN api.my_assignments.repository_template_provider IS 'Same as assignments.repository_template_provider: the forge of the template, NULL when the assignment has no self-serve repository'
; COMMENT ON COLUMN api.my_assignments.repository_template_full_name IS 'Same as assignments.repository_template_full_name: the owner/repo template, NULL when not configured'
; COMMENT ON COLUMN api.my_assignments.repository_url_field_slug IS 'Same as assignments.repository_url_field_slug: the URL field the provisioned repository is submitted through, NULL when not configured'
;
-- api.users carries the identity, read-only. The existing policy on
-- data."user" shows a student their own row, and a TA or faculty every row;
-- the authapp service reads it to render a profile. Faculty held INSERT and
-- UPDATE on the whole view, which would have made a PATCH of
-- github_verified_at a way to forge a verification. Their write privilege is
-- restated column by column over the columns they had, so the three new ones
-- are reachable only through api.set_user_github_identity and
-- api.import_github_logins.
CREATE OR REPLACE VIEW api.users AS
    SELECT
        id, email, netid, name, lastname, organization, known_as, nickname,
        role, created_at, updated_at, team_nickname, github_user_id,
        github_login, github_verified_at
    FROM data."user"
; ALTER VIEW api.users
    OWNER TO api
; REVOKE insert, update ON api.users FROM faculty
; GRANT insert (id, email, netid, name, lastname, organization, known_as, nickname, role, created_at, updated_at, team_nickname), update (id, email, netid, name, lastname, organization, known_as, nickname, role, created_at, updated_at, team_nickname) ON api.users TO faculty
; COMMENT ON COLUMN api.users.github_user_id IS 'GitHub account id linked to this user, NULL when none. Read-only here; set by the authapp service'
; COMMENT ON COLUMN api.users.github_login IS 'GitHub login linked to this user, NULL when none. Read-only here; set by the authapp service or a faculty import'
; COMMENT ON COLUMN api.users.github_verified_at IS 'When the platform verified the GitHub identity belongs to this user; NULL for a faculty-attested login'
;
-- ---------------------------------------------------------------------------
-- The service RPCs
-- ---------------------------------------------------------------------------
-- Every one of these reads and writes data.* directly rather than the api
-- views: a view runs under its owner's policies, which answer for the
-- caller's claim, and under the service claim they would show nothing.
--
-- Claim, or resume, an attempt for a student on an assignment. Returns the
-- attempt row plus existing_repository_id, which is NULL unless a repository
-- already exists for the owner, in which case the row is synthesized from it
-- (stage finalized) and no attempt is created or changed. That covers both a
-- student coming back after a successful provisioning and a repository the
-- old course tooling created.
CREATE FUNCTION api.claim_repository_provisioning(p_assignment_slug text, p_user_id int) RETURNS TABLE (id int, assignment_slug text, is_team boolean, user_id int, team_nickname text, initiated_by_user_id int, provider text, template_full_name text, destination_name text, provider_repo_id bigint, provider_full_name text, stage text, error_code text, last_checked_at timestamp with time zone, ready_at timestamp with time zone, created_at timestamp with time zone, updated_at timestamp with time zone, existing_repository_id int) SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    the_assignment data.assignment%ROWTYPE;
    the_user data."user"%ROWTYPE;
    owner_team text;
    owner_user int;
    the_repository data.assignment_repository%ROWTYPE;
    the_attempt data.assignment_repository_provisioning%ROWTYPE;
    effective_closed_at timestamptz;
    destination text;
BEGIN
    IF request.user_role() IS DISTINCT FROM 'app' OR request.app_name() IS DISTINCT FROM 'authapp' THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'insufficient_privilege',
                  DETAIL = 'only the authapp service may claim a repository provisioning';
    END IF;

    SELECT a.* INTO the_assignment FROM data.assignment a WHERE a.slug = p_assignment_slug;
    IF NOT FOUND OR the_assignment.is_draft OR the_assignment.repository_template_provider IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'repository_not_configured',
            DETAIL = format('assignment %s does not exist, is a draft, or has no repository template', p_assignment_slug);
    END IF;

    SELECT u.* INTO the_user FROM data."user" u WHERE u.id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown user id %', p_user_id USING ERRCODE = '22023';
    END IF;
    -- Repositories are provisioned for students. Staff and observers are
    -- refused before any lookup, including the existing-repository shortcut,
    -- so a TA's or faculty member's row here is never answered.
    IF the_user.role <> 'student' THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'not_a_student',
            DETAIL = format('user %s has role %s; only students provision repositories', p_user_id, the_user.role);
    END IF;

    IF the_assignment.is_team THEN
        IF the_user.team_nickname IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001',
                MESSAGE = 'no_team',
                DETAIL = format('%s is a team assignment and user %s is on no team', p_assignment_slug, p_user_id);
        END IF;
        owner_team := the_user.team_nickname;
    ELSE
        owner_user := p_user_id;
    END IF;

    -- Two clicks in flight for the same owner serialize here, so the second
    -- resumes the attempt the first created instead of tripping the unique
    -- index.
    PERFORM pg_advisory_xact_lock(hashtext('assignment_repository_provisioning:' || p_assignment_slug || ':' || coalesce(owner_team, owner_user::text)));

    SELECT r.* INTO the_repository
    FROM data.assignment_repository r
    WHERE r.assignment_slug = p_assignment_slug
      AND r.user_id IS NOT DISTINCT FROM owner_user
      AND r.team_nickname IS NOT DISTINCT FROM owner_team;

    SELECT p.* INTO the_attempt
    FROM data.assignment_repository_provisioning p
    WHERE p.assignment_slug = p_assignment_slug
      AND p.user_id IS NOT DISTINCT FROM owner_user
      AND p.team_nickname IS NOT DISTINCT FROM owner_team
    FOR UPDATE;

    IF the_repository.id IS NOT NULL THEN
        -- The attempt's id is carried when there is one, so readiness can
        -- still be recorded against it; the rest describes the repository.
        RETURN QUERY SELECT
            the_attempt.id, the_repository.assignment_slug, the_repository.is_team,
            the_repository.user_id, the_repository.team_nickname, p_user_id,
            the_repository.provider, the_assignment.repository_template_full_name,
            split_part(the_repository.provider_full_name, '/', 2),
            the_repository.provider_repo_id, the_repository.provider_full_name,
            'finalized'::text, NULL::text, the_attempt.last_checked_at, the_attempt.ready_at,
            the_repository.created_at, the_repository.updated_at, the_repository.id;
        RETURN;
    END IF;

    IF the_attempt.id IS NOT NULL THEN
        IF the_attempt.stage = 'failed' THEN
            UPDATE data.assignment_repository_provisioning p
            SET stage = 'claimed', error_code = NULL
            WHERE p.id = the_attempt.id
            RETURNING p.* INTO the_attempt;
        END IF;
        RETURN QUERY SELECT
            the_attempt.id, the_attempt.assignment_slug, the_attempt.is_team,
            the_attempt.user_id, the_attempt.team_nickname, the_attempt.initiated_by_user_id,
            the_attempt.provider, the_attempt.template_full_name, the_attempt.destination_name,
            the_attempt.provider_repo_id, the_attempt.provider_full_name,
            the_attempt.stage, the_attempt.error_code, the_attempt.last_checked_at, the_attempt.ready_at,
            the_attempt.created_at, the_attempt.updated_at, NULL::int;
        RETURN;
    END IF;

    -- A fresh attempt needs the assignment open for this owner: the later of
    -- the assignment's deadline and the owner's extension, the same rule
    -- data.assignment_field_submission_is_writable_by_current_user applies to
    -- the submission itself.
    SELECT GREATEST(the_assignment.closed_at, max(ge.closed_at)) INTO effective_closed_at
    FROM data.assignment_grade_exception ge
    WHERE ge.assignment_slug = p_assignment_slug
      AND ge.user_id IS NOT DISTINCT FROM owner_user
      AND ge.team_nickname IS NOT DISTINCT FROM owner_team;
    IF current_timestamp >= effective_closed_at THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'assignment_closed',
            DETAIL = format('%s closed for this owner at %s', p_assignment_slug, effective_closed_at);
    END IF;

    IF NOT the_assignment.is_team AND the_user.github_login IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'needs_github_link',
            DETAIL = format('user %s has no GitHub login on record', p_user_id);
    END IF;

    -- GitHub caps a repository name at 100 characters, which the table's CHECK
    -- restates. A legal slug plus a legal login or team nickname can exceed
    -- it, and that is a configuration problem to name, not a CHECK to trip.
    destination := p_assignment_slug || '-' || coalesce(owner_team, the_user.github_login);
    IF char_length(destination) > 100 THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'destination_name_too_long',
            DETAIL = format('%s is %s characters; the forge allows 100', destination, char_length(destination));
    END IF;

    INSERT INTO data.assignment_repository_provisioning (
        assignment_slug, is_team, user_id, team_nickname, initiated_by_user_id,
        provider, template_full_name, destination_name, stage
    )
    VALUES (
        p_assignment_slug, the_assignment.is_team, owner_user, owner_team, p_user_id,
        the_assignment.repository_template_provider, the_assignment.repository_template_full_name,
        destination, 'claimed'
    )
    RETURNING * INTO the_attempt;

    RETURN QUERY SELECT
        the_attempt.id, the_attempt.assignment_slug, the_attempt.is_team,
        the_attempt.user_id, the_attempt.team_nickname, the_attempt.initiated_by_user_id,
        the_attempt.provider, the_attempt.template_full_name, the_attempt.destination_name,
        the_attempt.provider_repo_id, the_attempt.provider_full_name,
        the_attempt.stage, the_attempt.error_code, the_attempt.last_checked_at, the_attempt.ready_at,
        the_attempt.created_at, the_attempt.updated_at, NULL::int;
END;
$$
; ALTER FUNCTION api.claim_repository_provisioning(text, int) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.claim_repository_provisioning(text, int) FROM public
; GRANT execute ON FUNCTION api.claim_repository_provisioning(text, int) TO app
; COMMENT ON FUNCTION api.claim_repository_provisioning(text, int) IS 'Claim or resume the repository provisioning attempt for a user on an assignment. authapp only. Returns the attempt, or a finalized row synthesized from an existing repository with existing_repository_id set. Refuses with repository_not_configured, not_a_student, no_team, assignment_closed, needs_github_link or destination_name_too_long.'
;
-- Record what the forge said. Transitions are forward only: claimed to
-- generated, generated to granted, anything not finalized to failed, and the
-- same stage again as a harmless repeat. A finalized attempt never changes.
CREATE FUNCTION api.record_repository_provisioning(p_attempt_id int, p_stage text, p_provider_repo_id bigint = NULL, p_provider_full_name text = NULL, p_error_code text = NULL) RETURNS SETOF api.assignment_repository_provisionings SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    the_attempt data.assignment_repository_provisioning%ROWTYPE;
BEGIN
    IF request.user_role() IS DISTINCT FROM 'app' OR request.app_name() IS DISTINCT FROM 'authapp' THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'insufficient_privilege',
                  DETAIL = 'only the authapp service may record a repository provisioning';
    END IF;

    SELECT p.* INTO the_attempt FROM data.assignment_repository_provisioning p WHERE p.id = p_attempt_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown provisioning attempt %', p_attempt_id USING ERRCODE = 'P0002';
    END IF;

    IF the_attempt.stage = 'finalized' THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'already_finalized',
            DETAIL = format('attempt %s is finalized and immutable', p_attempt_id);
    END IF;

    IF p_stage IS NULL OR NOT (
        p_stage = the_attempt.stage
        OR (the_attempt.stage = 'claimed' AND p_stage = 'generated')
        OR (the_attempt.stage = 'generated' AND p_stage = 'granted')
        OR p_stage = 'failed'
    ) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'invalid_stage_transition',
            DETAIL = format('attempt %s cannot move from %s to %s', p_attempt_id, the_attempt.stage, coalesce(p_stage, '(null)'));
    END IF;

    -- The repository's identity is written exactly once, on claimed to
    -- generated. A repeated generated has to say the same thing, so a retry
    -- that saw a different repository come back is a conflict and not a
    -- silent repoint; every other transition carries no repository at all.
    IF p_stage = 'generated' THEN
        IF p_provider_repo_id IS NULL OR p_provider_full_name IS NULL THEN
            RAISE EXCEPTION 'recording stage generated requires p_provider_repo_id and p_provider_full_name'
                USING ERRCODE = '22023';
        END IF;
        IF the_attempt.stage = 'generated'
            AND (the_attempt.provider_repo_id, the_attempt.provider_full_name)
                IS DISTINCT FROM (p_provider_repo_id, p_provider_full_name) THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001',
                MESSAGE = 'invalid_stage_transition',
                DETAIL = format('attempt %s already recorded repository %s %s; a repeated generated must name the same one', p_attempt_id, the_attempt.provider_repo_id, the_attempt.provider_full_name);
        END IF;
    ELSIF p_provider_repo_id IS NOT NULL OR p_provider_full_name IS NOT NULL THEN
        RAISE EXCEPTION 'a repository is recorded on stage generated only, not on %', p_stage
            USING ERRCODE = '22023';
    END IF;

    -- A failure without a code is a failure nobody can act on.
    IF p_stage = 'failed' AND p_error_code IS NULL THEN
        RAISE EXCEPTION 'recording stage failed requires p_error_code'
            USING ERRCODE = '22023';
    END IF;

    UPDATE data.assignment_repository_provisioning p
    SET stage = p_stage,
        provider_repo_id = coalesce(p_provider_repo_id, p.provider_repo_id),
        provider_full_name = coalesce(p_provider_full_name, p.provider_full_name),
        error_code = CASE WHEN p_stage = 'failed' THEN p_error_code END
    WHERE p.id = p_attempt_id;

    RETURN QUERY SELECT p.* FROM data.assignment_repository_provisioning p WHERE p.id = p_attempt_id;
END;
$$
; ALTER FUNCTION api.record_repository_provisioning(int, text, bigint, text, text) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.record_repository_provisioning(int, text, bigint, text, text) FROM public
; GRANT execute ON FUNCTION api.record_repository_provisioning(int, text, bigint, text, text) TO app
; COMMENT ON FUNCTION api.record_repository_provisioning(int, text, bigint, text, text) IS 'Advance a provisioning attempt: claimed to generated (with the forge id and name), generated to granted, or any unfinalized stage to failed with a stable error code. authapp only. Refuses with invalid_stage_transition or already_finalized.'
;
-- Finalize: the repository row, the submission and the URL field submission
-- in one call, which is one transaction. Requires stage granted. The deadline
-- is deliberately not checked here: the attempt was claimed while open, and
-- an attempt that the forge finished after the deadline still belongs to the
-- student. Origin is stated explicitly, as `admin provision-repos` did; the
-- field-submission defaults trigger classifies only student, ta and faculty
-- claims, so under the service claim the stated origin stands and cannot be
-- set to anything by a student request.
--
-- A finalized attempt finalizes again as a no-op that returns the repository
-- row: authapp cannot tell a lost response from a failed call, and the retry
-- has to be safe.
CREATE FUNCTION api.finalize_repository_provisioning(p_attempt_id int, p_repo_url text, p_provider_user_id bigint = NULL) RETURNS SETOF api.assignment_repositories SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    the_attempt data.assignment_repository_provisioning%ROWTYPE;
    the_assignment data.assignment%ROWTYPE;
    the_field data.assignment_field%ROWTYPE;
    the_repository data.assignment_repository%ROWTYPE;
    owner_github_user_id bigint;
    submission_id int;
    existing_body text;
BEGIN
    IF request.user_role() IS DISTINCT FROM 'app' OR request.app_name() IS DISTINCT FROM 'authapp' THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'insufficient_privilege',
                  DETAIL = 'only the authapp service may finalize a repository provisioning';
    END IF;

    SELECT p.* INTO the_attempt FROM data.assignment_repository_provisioning p WHERE p.id = p_attempt_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown provisioning attempt %', p_attempt_id USING ERRCODE = 'P0002';
    END IF;

    IF the_attempt.stage = 'finalized' THEN
        RETURN QUERY SELECT r.*
        FROM data.assignment_repository r
        WHERE r.assignment_slug = the_attempt.assignment_slug
          AND r.user_id IS NOT DISTINCT FROM the_attempt.user_id
          AND r.team_nickname IS NOT DISTINCT FROM the_attempt.team_nickname;
        RETURN;
    END IF;

    IF the_attempt.stage <> 'granted' THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'invalid_stage_transition',
            DETAIL = format('attempt %s is at stage %s and only a granted attempt can be finalized', p_attempt_id, the_attempt.stage);
    END IF;

    SELECT a.* INTO the_assignment FROM data.assignment a WHERE a.slug = the_attempt.assignment_slug;
    IF the_assignment.repository_url_field_slug IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'repository_not_configured',
            DETAIL = format('assignment %s no longer has a repository template', the_attempt.assignment_slug);
    END IF;
    SELECT f.* INTO the_field
    FROM data.assignment_field f
    WHERE f.assignment_slug = the_assignment.slug
      AND f.slug = the_assignment.repository_url_field_slug;

    -- The URL is bound to the repository the attempt recorded at generate,
    -- so a caller cannot finalize one repository and hand in another. On
    -- GitHub the browser URL is exactly the full name; on any other forge the
    -- full name at least has to appear in it.
    IF p_repo_url IS NULL
        OR (the_attempt.provider = 'github' AND p_repo_url <> 'https://github.com/' || the_attempt.provider_full_name)
        OR (the_attempt.provider <> 'github' AND position(the_attempt.provider_full_name IN p_repo_url) = 0) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'repo_url_mismatch',
            DETAIL = format('the URL does not name repository %s on %s', the_attempt.provider_full_name, the_attempt.provider);
    END IF;

    -- Checked up front so the refusal names itself; the table's own CHECK
    -- constraints would refuse the same body a few statements later.
    IF NOT data.text_is_url(p_repo_url) OR NOT data.text_matches(p_repo_url, the_field.pattern) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'url_pattern_mismatch',
            DETAIL = format('the repository URL does not satisfy field %s of %s', the_field.slug, the_assignment.slug);
    END IF;

    -- The forge account the repository was granted to has to be the one the
    -- student linked, when both are known. A team repository has no single
    -- account and is not checked.
    IF the_attempt.user_id IS NOT NULL AND p_provider_user_id IS NOT NULL THEN
        SELECT u.github_user_id INTO owner_github_user_id FROM data."user" u WHERE u.id = the_attempt.user_id;
        IF owner_github_user_id IS NOT NULL AND owner_github_user_id <> p_provider_user_id THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001',
                MESSAGE = 'github_identity_mismatch',
                DETAIL = format('user %s is linked to GitHub account %s, not %s', the_attempt.user_id, owner_github_user_id, p_provider_user_id);
        END IF;
    END IF;

    -- 1. The repository row. An existing row for this owner is reused when it
    -- is the same repository; a different one is a conflict for staff, never
    -- an overwrite. The same forge repository recorded for another owner is a
    -- conflict too, before the unique index says so less clearly.
    SELECT r.* INTO the_repository
    FROM data.assignment_repository r
    WHERE r.assignment_slug = the_attempt.assignment_slug
      AND r.user_id IS NOT DISTINCT FROM the_attempt.user_id
      AND r.team_nickname IS NOT DISTINCT FROM the_attempt.team_nickname;
    IF FOUND THEN
        IF the_repository.provider <> the_attempt.provider OR the_repository.provider_repo_id <> the_attempt.provider_repo_id THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001',
                MESSAGE = 'repository_conflict',
                DETAIL = format('a different repository (%s %s) is already recorded for this owner on %s', the_repository.provider, the_repository.provider_repo_id, the_attempt.assignment_slug);
        END IF;
    ELSE
        IF EXISTS (
            SELECT 1 FROM data.assignment_repository r
            WHERE r.provider = the_attempt.provider AND r.provider_repo_id = the_attempt.provider_repo_id
        ) THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001',
                MESSAGE = 'repository_conflict',
                DETAIL = format('repository %s %s is already recorded for another owner', the_attempt.provider, the_attempt.provider_repo_id);
        END IF;
        INSERT INTO data.assignment_repository (
            assignment_slug, is_team, user_id, team_nickname,
            provider, provider_repo_id, provider_full_name, provider_user_id
        )
        VALUES (
            the_attempt.assignment_slug, the_attempt.is_team, the_attempt.user_id, the_attempt.team_nickname,
            the_attempt.provider, the_attempt.provider_repo_id, the_attempt.provider_full_name, p_provider_user_id
        )
        RETURNING * INTO the_repository;
    END IF;

    -- 2. The submission, created if the owner has none. The participant
    -- snapshot trigger fills in the team as it stands now.
    SELECT s.id INTO submission_id
    FROM data.assignment_submission s
    WHERE s.assignment_slug = the_attempt.assignment_slug
      AND s.user_id IS NOT DISTINCT FROM the_attempt.user_id
      AND s.team_nickname IS NOT DISTINCT FROM the_attempt.team_nickname;
    IF NOT FOUND THEN
        INSERT INTO data.assignment_submission (assignment_slug, is_team, user_id, team_nickname, submitter_user_id)
        VALUES (the_attempt.assignment_slug, the_attempt.is_team, the_attempt.user_id, the_attempt.team_nickname, the_attempt.initiated_by_user_id)
        RETURNING id INTO submission_id;
    END IF;

    -- 3. The URL field. A value already there is the student's, or an earlier
    -- finalize's: identical is a no-op, different is a conflict.
    SELECT fs.body INTO existing_body
    FROM data.assignment_field_submission fs
    WHERE fs.assignment_submission_id = submission_id
      AND fs.assignment_field_slug = the_field.slug;
    IF FOUND THEN
        IF existing_body <> p_repo_url THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001',
                MESSAGE = 'submission_conflict',
                DETAIL = format('field %s of submission %s already holds a different value', the_field.slug, submission_id);
        END IF;
    ELSE
        INSERT INTO data.assignment_field_submission (
            assignment_submission_id, assignment_field_slug, assignment_slug,
            body, submitter_user_id, origin
        )
        VALUES (
            submission_id, the_field.slug, the_assignment.slug,
            p_repo_url, the_attempt.initiated_by_user_id, 'provisioning'
        );
    END IF;

    -- 4. The attempt is done.
    UPDATE data.assignment_repository_provisioning p
    SET stage = 'finalized', error_code = NULL
    WHERE p.id = p_attempt_id;

    RETURN QUERY SELECT r.* FROM data.assignment_repository r WHERE r.id = the_repository.id;
END;
$$
; ALTER FUNCTION api.finalize_repository_provisioning(int, text, bigint) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.finalize_repository_provisioning(int, text, bigint) FROM public
; GRANT execute ON FUNCTION api.finalize_repository_provisioning(int, text, bigint) TO app
; COMMENT ON FUNCTION api.finalize_repository_provisioning(int, text, bigint) IS 'Finish a granted provisioning attempt in one transaction: record the repository, create the owner''s submission if missing, and submit the repository URL through the assignment''s URL field with origin provisioning. authapp only. Idempotent once finalized. Refuses with invalid_stage_transition, repo_url_mismatch, url_pattern_mismatch, github_identity_mismatch, repository_conflict or submission_conflict.'
;
-- Readiness, for the poll that waits for the template contents to land
-- (#396). ready_at is set once and never moved.
CREATE FUNCTION api.touch_repository_provisioning_readiness(p_attempt_id int, p_ready boolean) RETURNS SETOF api.assignment_repository_provisionings SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    attempt_stage text;
BEGIN
    IF request.user_role() IS DISTINCT FROM 'app' OR request.app_name() IS DISTINCT FROM 'authapp' THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'insufficient_privilege',
                  DETAIL = 'only the authapp service may record provisioning readiness';
    END IF;

    SELECT p.stage INTO attempt_stage FROM data.assignment_repository_provisioning p WHERE p.id = p_attempt_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown provisioning attempt %', p_attempt_id USING ERRCODE = 'P0002';
    END IF;
    -- Readiness is a property of a repository that exists, so there is
    -- nothing to check before generate returned or after a failure.
    IF attempt_stage NOT IN ('generated', 'granted', 'finalized') THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'invalid_stage_transition',
            DETAIL = format('attempt %s is at stage %s and has no repository to check', p_attempt_id, attempt_stage);
    END IF;

    UPDATE data.assignment_repository_provisioning p
    SET last_checked_at = current_timestamp,
        ready_at = CASE WHEN coalesce(p_ready, false) THEN coalesce(p.ready_at, current_timestamp) ELSE p.ready_at END
    WHERE p.id = p_attempt_id;

    RETURN QUERY SELECT p.* FROM data.assignment_repository_provisioning p WHERE p.id = p_attempt_id;
END;
$$
; ALTER FUNCTION api.touch_repository_provisioning_readiness(int, boolean) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.touch_repository_provisioning_readiness(int, boolean) FROM public
; GRANT execute ON FUNCTION api.touch_repository_provisioning_readiness(int, boolean) TO app
; COMMENT ON FUNCTION api.touch_repository_provisioning_readiness(int, boolean) IS 'Record that the service checked whether a provisioned repository''s contents are ready, and when they first were. authapp only.'
;
-- The GitHub identity, written by the service. The id is one account per
-- person: another user holding it is refused. A user whose id changes after a
-- repository was provisioned for them is refused too, because the forge
-- grants went to the old account and only staff can untangle that.
-- verified_at is set by a verified call and kept by an unverified one that
-- says the same account; an unverified call that names a different account
-- clears it, since the old verification was of the old account.
CREATE FUNCTION api.set_user_github_identity(p_user_id int, p_github_user_id bigint, p_github_login text, p_verified boolean) RETURNS SETOF api.users SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    the_user data."user"%ROWTYPE;
BEGIN
    IF request.user_role() IS DISTINCT FROM 'app' OR request.app_name() IS DISTINCT FROM 'authapp' THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'insufficient_privilege',
                  DETAIL = 'only the authapp service may set a GitHub identity';
    END IF;

    IF p_github_user_id IS NULL OR p_github_login IS NULL THEN
        RAISE EXCEPTION 'p_github_user_id and p_github_login are required' USING ERRCODE = '22023';
    END IF;

    SELECT u.* INTO the_user FROM data."user" u WHERE u.id = p_user_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown user id %', p_user_id USING ERRCODE = '22023';
    END IF;

    IF EXISTS (SELECT 1 FROM data."user" u WHERE u.github_user_id = p_github_user_id AND u.id <> p_user_id) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'github_identity_taken',
            DETAIL = format('GitHub account %s is linked to another user', p_github_user_id);
    END IF;

    -- Locked once a repository has been granted to the old account: the
    -- user's own repositories, whether an attempt finalized them or the old
    -- tooling recorded them, and a current team's repository that was
    -- granted to this account.
    IF the_user.github_user_id IS NOT NULL
        AND the_user.github_user_id <> p_github_user_id
        AND (
            EXISTS (
                SELECT 1 FROM data.assignment_repository_provisioning p
                WHERE p.stage = 'finalized'
                  AND (p.user_id = p_user_id OR p.initiated_by_user_id = p_user_id)
            )
            OR EXISTS (
                SELECT 1 FROM data.assignment_repository r
                WHERE r.user_id = p_user_id
                   OR (r.team_nickname = the_user.team_nickname
                       AND r.provider_user_id = the_user.github_user_id)
            )
        ) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'github_identity_locked',
            DETAIL = format('user %s has a provisioned repository under GitHub account %s; staff must resolve the change', p_user_id, the_user.github_user_id);
    END IF;

    -- The unique indexes on the account id and on lower(login) are the last
    -- word; a race past the check above, or a login another user holds, is
    -- reported the same way rather than as a bare unique violation.
    BEGIN
        UPDATE data."user" u
        SET github_user_id = p_github_user_id,
            github_login = p_github_login,
            github_verified_at = CASE
                WHEN coalesce(p_verified, false) THEN current_timestamp
                WHEN u.github_user_id IS DISTINCT FROM p_github_user_id THEN NULL
                ELSE u.github_verified_at
            END
        WHERE u.id = p_user_id;
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'github_identity_taken',
            DETAIL = format('GitHub account %s or login %s is linked to another user', p_github_user_id, p_github_login);
    END;

    RETURN QUERY SELECT
        u.id, u.email, u.netid, u.name, u.lastname, u.organization, u.known_as, u.nickname,
        u.role, u.created_at, u.updated_at, u.team_nickname, u.github_user_id,
        u.github_login, u.github_verified_at
    FROM data."user" u WHERE u.id = p_user_id;
END;
$$
; ALTER FUNCTION api.set_user_github_identity(int, bigint, text, boolean) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.set_user_github_identity(int, bigint, text, boolean) FROM public
; GRANT execute ON FUNCTION api.set_user_github_identity(int, bigint, text, boolean) TO app
; COMMENT ON FUNCTION api.set_user_github_identity(int, bigint, text, boolean) IS 'Link a GitHub account to a user, verified or not. authapp only. Refuses with github_identity_taken when another user holds the account or the login, and github_identity_locked when the user already holds a repository granted under a different account.'
;
-- The phase-one bootstrap: faculty copy logins out of a field students
-- already submitted (the course's github-username assignment). Attested, not
-- verified, so verified_at is NULL and the id is left alone. A body that is
-- not a login is skipped, not an error, so one typo does not block the class.
CREATE FUNCTION api.import_github_logins(p_assignment_slug text, p_field_slug text) RETURNS int SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    updated int;
BEGIN
    IF request.user_role() IS DISTINCT FROM 'faculty' THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'insufficient_privilege',
                  DETAIL = 'only faculty may import GitHub logins';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM data.assignment_field f
        WHERE f.assignment_slug = p_assignment_slug AND f.slug = p_field_slug
    ) THEN
        RAISE EXCEPTION 'no field % on assignment %', p_field_slug, p_assignment_slug USING ERRCODE = '22023';
    END IF;

    -- A login another user already holds, or that two submissions claim, is
    -- skipped like a malformed one: the import never decides who owns a
    -- login, it only copies uncontested ones.
    WITH candidate AS (
        SELECT s.user_id, btrim(fs.body) AS login
        FROM data.assignment_field_submission fs
        JOIN data.assignment_submission s ON s.id = fs.assignment_submission_id
        WHERE fs.assignment_slug = p_assignment_slug
          AND fs.assignment_field_slug = p_field_slug
          AND s.user_id IS NOT NULL
          AND btrim(fs.body) ~ '^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$'
          AND NOT EXISTS (
              SELECT 1 FROM data."user" holder
              WHERE lower(holder.github_login) = lower(btrim(fs.body))
                AND holder.id <> s.user_id
          )
          AND (SELECT count(*) FROM data.assignment_field_submission other
               WHERE other.assignment_slug = p_assignment_slug
                 AND other.assignment_field_slug = p_field_slug
                 AND lower(btrim(other.body)) = lower(btrim(fs.body))) = 1
    ),
    changed AS (
        UPDATE data."user" u
        SET github_login = candidate.login, github_verified_at = NULL
        FROM candidate
        WHERE u.id = candidate.user_id AND u.github_login IS NULL
        RETURNING u.id
    )
    SELECT count(*)::int INTO updated FROM changed;

    RETURN updated;
END;
$$
; ALTER FUNCTION api.import_github_logins(text, text) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.import_github_logins(text, text) FROM public
; GRANT execute ON FUNCTION api.import_github_logins(text, text) TO faculty
; COMMENT ON FUNCTION api.import_github_logins(text, text) IS 'Faculty bootstrap: set github_login for every user with no login yet from their submission to the given field, when the trimmed body is a GitHub login nobody else holds. Attested only: github_verified_at is left NULL. Returns the number of users updated.'
;
-- ---------------------------------------------------------------------------
-- Compatibility
-- ---------------------------------------------------------------------------
-- Shape 8: api.assignment_repository_provisionings, and columns appended to
-- api.assignments, api.my_assignments and api.users. admin_api_version 15:
-- the six RPCs above. Set membership for the shape, a floor for the RPCs --
-- see docs/platform-compatibility.md.
CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::int AS platform_compatibility_version,
        8::int AS schema_compatibility_version, 15::int AS admin_api_version
; ALTER VIEW api.platform_version
    OWNER TO api
;
-- PostgREST caches the schema; without this it keeps serving without the new
-- view, columns and RPCs.
NOTIFY pgrst, 'reload schema'
