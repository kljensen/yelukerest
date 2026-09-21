-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.
-- Self-serve repositories: repository templates, GitHub identity, and the
-- provisioning attempt with its service RPCs (issue #394, roadmap 17).
--
-- data.assignment_repository (01a011e3) records a repository once the forge
-- has returned its id. It cannot say which template the repository was
-- generated from, or that an attempt is under way and where it got to.
-- `admin provision-repos` kept both in a course repo and its own memory.
-- This migration moves the template, the attempt and the finalizing write
-- into the database, where the deadline, the team roster and the RLS
-- already are. authapp (#395, #396) drives the forge and calls the RPCs
-- below; it holds no course data of its own.
--
-- A repository is a thing a student creates from a template, on their own
-- page, and hands in by pasting its URL into whatever assignment field asks
-- for one. Nothing here writes a submission: the template may name the
-- assignment it is meant for, which governs the deadline and lets a client
-- offer the URL, and that is the whole of the coupling.
--
-- Four changes, in order:
--   * data."user" gains the student's GitHub identity: the numeric account
--     id (identity), the login (display, and the repository name), and when
--     the platform verified the link. Phase one fills the login from a
--     faculty import with verified_at NULL; phase two (#399) verifies.
--   * data.repository_template is what faculty configure: the forge, the
--     template repository, a label for the page, whether it is for teams,
--     and optionally the assignment it serves.
--   * data.assignment_repository is keyed by template rather than by
--     assignment: template_slug arrives NOT NULL, assignment_slug becomes
--     optional, and one-per-owner is per template. Existing rows are
--     carried over by a template synthesized from their assignment.
--   * data.assignment_repository_provisioning is the attempt: claimed by
--     the student's click, advanced by authapp as the forge answers,
--     finalized into a repository row. One attempt per owner per template.
--
-- The RPCs are SECURITY DEFINER, owned by yelukerest_migrator like
-- api.exchange_user_api_token, and admit only the authapp service credential
-- (role app, app_name authapp), except api.import_github_logins which is the
-- faculty bootstrap. The guards compare with IS DISTINCT FROM: a session with
-- no role or no app_name claim at all must be refused, and `NOT (NULL AND x)`
-- is NULL, which an IF treats as false. Every refusal a client should branch
-- on is raised with a stable code as the MESSAGE and the explanation in
-- DETAIL, so authapp maps the message and never parses prose.
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
-- data.repository_template: what a student can create a repository from
-- ---------------------------------------------------------------------------
-- The slug is the key a client and a URL carry, and the first half of the
-- repository name, so it has the assignment slug's shape. provider is
-- constrained to the same slug shape as assignment_repository.provider, so
-- the two never disagree on what to call a forge. template_full_name is
-- owner/repo: a GitHub owner is a login (no leading, trailing or doubled
-- hyphen), and a repository name is a dotted token.
--
-- assignment_slug is optional, and foreign-keyed together with is_team to
-- (assignment.slug, assignment.is_team) as data.assignment_repository is, so
-- a team template can only serve a team assignment. The key is MATCH
-- SIMPLE, PostgreSQL's default, and a NULL assignment_slug satisfies it.
-- (slug, is_team) is unique for the same reason (assignment.slug,
-- assignment.is_team) is: the repository and attempt tables key on both, so
-- a team repository from an individual template is unrepresentable.
CREATE TABLE data.repository_template (
    slug text PRIMARY KEY CHECK (slug ~ '^[a-z0-9-]+$'
    AND char_length(slug) <= 60),
    provider text NOT NULL DEFAULT 'github' CHECK (provider ~ '^[a-z][a-z0-9_-]{0,31}$'),
    template_full_name text NOT NULL CHECK (template_full_name ~ '^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}/[A-Za-z0-9._-]+$'
    AND char_length(template_full_name) BETWEEN 3 AND 255),
    label text NOT NULL CHECK (char_length(label) BETWEEN 1 AND 100),
    description text CHECK (char_length(description) <= 500),
    is_team boolean NOT NULL DEFAULT false,
    assignment_slug text CHECK (char_length(assignment_slug) < 100),
    FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment (slug, is_team) ON UPDATE CASCADE,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamp with time zone NOT NULL DEFAULT current_timestamp,
    updated_at timestamp with time zone NOT NULL DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    UNIQUE (slug, is_team)
)
; ALTER TABLE data.repository_template
    OWNER TO yelukerest_migrator
;
-- Foreign key index, as tests/db/foreign-key-indexes.sql requires.
CREATE INDEX idx_repository_template_assignment_fk
ON data.repository_template USING btree (assignment_slug, is_team)
; CREATE TRIGGER tg_repository_template_update_timestamps BEFORE INSERT OR UPDATE ON data.repository_template FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column()
; COMMENT ON TABLE data.repository_template IS 'A forge template repository students may create their own repository from, optionally tied to the assignment it serves'
;
-- ---------------------------------------------------------------------------
-- data.assignment_repository: keyed by template
-- ---------------------------------------------------------------------------
-- Backfill. Rows the old course tooling recorded name an assignment and no
-- template. For each distinct (assignment_slug, is_team) among them a
-- template is synthesized with slug = assignment_slug, template_full_name =
-- 'unknown/' || assignment_slug, label = the assignment title, and the rows
-- point at it. The synthesized template is inactive: its owner/repo is a
-- placeholder nobody could generate from, so students must not see or claim
-- it until faculty set the real template and activate it. Uniqueness per
-- owner and assignment therefore carries over as uniqueness per owner and
-- template.
ALTER TABLE data.assignment_repository
    ADD COLUMN template_slug text CHECK (char_length(template_slug) <= 60),
    ALTER COLUMN assignment_slug DROP NOT NULL
; INSERT INTO data.repository_template (slug, provider, template_full_name, label, is_team, assignment_slug, is_active)
SELECT
    r.assignment_slug, min(r.provider), 'unknown/' || r.assignment_slug,
    COALESCE(NULLIF(a.title, ''), a.slug), r.is_team, r.assignment_slug, false
FROM
    data.assignment_repository r
    JOIN data.assignment a ON a.slug = r.assignment_slug
GROUP BY r.assignment_slug, r.is_team, a.title, a.slug
; UPDATE data.assignment_repository
SET template_slug = assignment_slug
; ALTER TABLE data.assignment_repository
    ALTER COLUMN template_slug SET NOT NULL,
    ADD FOREIGN KEY (template_slug, is_team) REFERENCES data.repository_template (slug, is_team) ON UPDATE CASCADE
;
-- One repository per student per template, and per team per template, in
-- place of per assignment. The partial predicates are as before: NULLs are
-- distinct in a unique index. The (provider, provider_repo_id) key stays.
DROP INDEX data.assignment_repository_unique_user
; DROP INDEX data.assignment_repository_unique_team
; CREATE UNIQUE INDEX assignment_repository_unique_user
ON data.assignment_repository USING btree (user_id, template_slug)
WHERE team_nickname IS NULL
; CREATE UNIQUE INDEX assignment_repository_unique_team
ON data.assignment_repository USING btree (team_nickname, template_slug)
WHERE user_id IS NULL
; CREATE INDEX idx_assignment_repository_template_fk
ON data.assignment_repository USING btree (template_slug, is_team)
; COMMENT ON COLUMN data.assignment_repository.template_slug IS 'The template the repository was created from. Backfilled for pre-template rows with a template named after the assignment. Issue #394.'
;
-- A repository's assignment is its template's, never a writer's choice: an
-- omitted assignment_slug is filled from the template, and an explicit one
-- that differs is refused, so faculty tooling writing through
-- api.assignment_repositories cannot attribute a repository to an assignment
-- its template does not serve. The one legitimate difference is the
-- assignment the owner's attempt on this template was claimed under: the
-- attempt snapshots it (below), and finalize records the snapshot even if
-- faculty have since re-pointed the template. Only insert and a change of
-- assignment or template are checked, so a rename of a legacy row whose
-- template has moved on is not refused. Runs as the definer because faculty
-- hold nothing on the data schema, as the existing lookup triggers do.
CREATE FUNCTION data.keep_assignment_repository_assignment() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO data, pg_temp AS $$
DECLARE
    template_assignment text;
BEGIN
    IF TG_OP = 'UPDATE'
        AND NEW.assignment_slug IS NOT DISTINCT FROM OLD.assignment_slug
        AND NEW.template_slug IS NOT DISTINCT FROM OLD.template_slug THEN
        RETURN NEW;
    END IF;
    SELECT t.assignment_slug INTO template_assignment
    FROM data.repository_template t
    WHERE t.slug = NEW.template_slug;
    IF NEW.assignment_slug IS NULL THEN
        NEW.assignment_slug := template_assignment;
        RETURN NEW;
    END IF;
    IF NEW.assignment_slug IS DISTINCT FROM template_assignment
        AND NOT EXISTS (
            SELECT 1
            FROM data.assignment_repository_provisioning p
            WHERE p.template_slug = NEW.template_slug
              AND p.user_id IS NOT DISTINCT FROM NEW.user_id
              AND p.team_nickname IS NOT DISTINCT FROM NEW.team_nickname
              AND p.assignment_slug = NEW.assignment_slug
        ) THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'repository_assignment_mismatch',
            DETAIL = format('template %s serves assignment %s, not %s', NEW.template_slug, coalesce(template_assignment, '(none)'), NEW.assignment_slug);
    END IF;
    RETURN NEW;
END;
$$
; ALTER FUNCTION data.keep_assignment_repository_assignment() OWNER TO yelukerest_migrator
;
-- Faculty configure templates; students read them. A student reads the
-- active ones, which are what the page offers, and also any template one of
-- their own repositories was created from, so deactivating a template never
-- makes a repository vanish from api.my_repositories, which joins here. The
-- policy names assignment_repository.template_slug, hence its place after
-- that column exists.
GRANT select, insert, update, delete ON data.repository_template TO api
; ALTER TABLE data.repository_template
    ENABLE ROW LEVEL SECURITY
; CREATE POLICY repository_template_access_policy ON data.repository_template TO api USING (request.user_role() = 'faculty' OR (request.user_role() = ANY('{student,ta}'::text[])
AND (is_active OR EXISTS (
    SELECT 1
    FROM data.assignment_repository r
    WHERE
        r.template_slug = repository_template.slug
        AND (r.user_id = request.user_id() OR (r.team_nickname IS NOT NULL
        AND r.team_nickname = (
            SELECT u.team_nickname
            FROM data."user" u
            WHERE u.id = request.user_id()
        )))
)))) WITH CHECK (request.user_role() = 'faculty')
; CREATE VIEW api.repository_templates AS
    SELECT *
    FROM data.repository_template
; ALTER VIEW api.repository_templates
    OWNER TO api
; GRANT select ON api.repository_templates TO student, ta
; GRANT select, insert, update, delete ON api.repository_templates TO faculty
; COMMENT ON VIEW api.repository_templates IS 'Template repositories a student may create a repository from. Faculty configure them here; students read the active ones'
; COMMENT ON COLUMN api.repository_templates.slug IS 'Key for the template, and the first half of the name of every repository created from it'
; COMMENT ON COLUMN api.repository_templates.provider IS 'Forge the template repository lives on, such as github'
; COMMENT ON COLUMN api.repository_templates.template_full_name IS 'Template repository as owner/repo on the provider'
; COMMENT ON COLUMN api.repository_templates.label IS 'What the repositories page calls this template, such as "Go programming starter"'
; COMMENT ON COLUMN api.repository_templates.description IS 'One optional line under the label'
; COMMENT ON COLUMN api.repository_templates.is_team IS 'True when a repository from this template belongs to a team rather than a student'
; COMMENT ON COLUMN api.repository_templates.assignment_slug IS 'The assignment this template serves, if any: its deadline governs creation, and a client may offer the repository URL for it. NULL for a template tied to no assignment'
; COMMENT ON COLUMN api.repository_templates.is_active IS 'Whether students may create repositories from it now. Existing repositories are unaffected'
; COMMENT ON COLUMN api.repository_templates.created_at IS 'When this template was created'
; COMMENT ON COLUMN api.repository_templates.updated_at IS 'When this template was last changed'
;
-- The view keeps its name and its columns; template_slug is appended, which
-- CREATE OR REPLACE permits. Faculty tooling that writes here now has to
-- name a template.
CREATE OR REPLACE VIEW api.assignment_repositories AS
    SELECT *
    FROM data.assignment_repository
; ALTER VIEW api.assignment_repositories
    OWNER TO api
; COMMENT ON COLUMN api.assignment_repositories.assignment_slug IS 'The assignment the repository was created for, copied from its template. NULL when the template serves no assignment'
; COMMENT ON COLUMN api.assignment_repositories.template_slug IS 'The template the repository was created from'
;
-- The caller's repositories, for the repositories page and the assignment
-- page: own rows and the current team's, with the template's label and
-- assignment and the browser URL. The row policy on
-- data.assignment_repository already narrows a student to these; the WHERE
-- makes the view mean "mine" for faculty too. assignment_slug is the
-- repository's own, which the trigger above keeps equal to the template's
-- except for an attempt's snapshot, so a client matching a repository to an
-- assignment page sees the assignment the repository was created for.
CREATE VIEW api.my_repositories WITH (security_barrier=true) AS
    SELECT
        r.id, r.template_slug, t.label, r.assignment_slug, t.template_full_name,
        r.is_team, r.user_id, r.team_nickname, r.provider, r.provider_repo_id,
        r.provider_full_name,
        CASE
            WHEN r.provider = 'github' THEN 'https://github.com/' || r.provider_full_name
        END AS repo_url,
        r.created_at, r.updated_at
    FROM
        data.assignment_repository r
        JOIN data.repository_template t ON t.slug = r.template_slug
    WHERE
        r.user_id = request.user_id() OR (r.team_nickname IS NOT NULL
        AND r.team_nickname = (
            SELECT u.team_nickname
            FROM data."user" u
            WHERE u.id = request.user_id()
        ))
; ALTER VIEW api.my_repositories
    OWNER TO api
; GRANT select ON api.my_repositories TO student, ta, faculty
; COMMENT ON VIEW api.my_repositories IS 'The calling user''s repositories: their own and their current team''s, with the template''s label and assignment and the browser URL. Read-only'
; COMMENT ON COLUMN api.my_repositories.id IS 'Same as assignment_repositories.id'
; COMMENT ON COLUMN api.my_repositories.template_slug IS 'The template the repository was created from'
; COMMENT ON COLUMN api.my_repositories.label IS 'The template''s label'
; COMMENT ON COLUMN api.my_repositories.assignment_slug IS 'The assignment the repository was created for, NULL when its template served none'
; COMMENT ON COLUMN api.my_repositories.template_full_name IS 'The template repository as owner/repo'
; COMMENT ON COLUMN api.my_repositories.is_team IS 'True when the repository belongs to the caller''s team'
; COMMENT ON COLUMN api.my_repositories.user_id IS 'Owning student, NULL for a team repository'
; COMMENT ON COLUMN api.my_repositories.team_nickname IS 'Owning team, NULL for an individual repository'
; COMMENT ON COLUMN api.my_repositories.provider IS 'Forge hosting the repository, such as github'
; COMMENT ON COLUMN api.my_repositories.provider_repo_id IS 'Forge repository id'
; COMMENT ON COLUMN api.my_repositories.provider_full_name IS 'Forge repository name such as org/repo'
; COMMENT ON COLUMN api.my_repositories.repo_url IS 'Browser URL of the repository: https://github.com/<full name> on github, NULL on a forge this view does not know'
; COMMENT ON COLUMN api.my_repositories.created_at IS 'When the repository record was created'
; COMMENT ON COLUMN api.my_repositories.updated_at IS 'When the repository record was last changed'
;
-- ---------------------------------------------------------------------------
-- data.assignment_repository_provisioning: the attempt
-- ---------------------------------------------------------------------------
-- Shaped after data.assignment_repository: the same (template_slug, is_team)
-- foreign key, the same user XOR team check, the same one-per-owner partial
-- unique indexes. What it adds is the state of an attempt: the template,
-- the assignment it served and the destination name as they were when the
-- student clicked, the forge id once generate has returned it, the stage,
-- and a sanitized error code. The assignment is snapshotted because the
-- deadline was checked against it at the click, and finalize records the
-- repository under it even if faculty re-point the template meanwhile. No
-- lease: an attempt that is not finalized is simply resumed by the next
-- request.
--
-- provider_repo_id is NOT unique here on purpose. A failed attempt may hold
-- the id of a repository that was generated and then lost, and a later
-- attempt for another owner must not be refused by it; uniqueness belongs to
-- data.assignment_repository, which finalize writes.
CREATE TABLE data.assignment_repository_provisioning (
    id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    template_slug text NOT NULL CHECK (char_length(template_slug) <= 60),
    is_team boolean NOT NULL,
    FOREIGN KEY (template_slug, is_team) REFERENCES data.repository_template (slug, is_team) ON UPDATE CASCADE,
    assignment_slug text CHECK (char_length(assignment_slug) < 100),
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
    CONSTRAINT matches_template_is_team CHECK ((is_team
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
ON data.assignment_repository_provisioning USING btree (user_id, template_slug)
WHERE team_nickname IS NULL
; CREATE UNIQUE INDEX assignment_repository_provisioning_unique_team
ON data.assignment_repository_provisioning USING btree (team_nickname, template_slug)
WHERE user_id IS NULL
;
-- Foreign key indexes, as tests/db/foreign-key-indexes.sql requires.
CREATE INDEX idx_assignment_repository_provisioning_template_fk
ON data.assignment_repository_provisioning USING btree (template_slug, is_team)
; CREATE INDEX idx_assignment_repository_provisioning_assignment_fk
ON data.assignment_repository_provisioning USING btree (assignment_slug, is_team)
; CREATE INDEX idx_assignment_repository_provisioning_user_fk
ON data.assignment_repository_provisioning USING btree (user_id)
; CREATE INDEX idx_assignment_repository_provisioning_team_fk
ON data.assignment_repository_provisioning USING btree (team_nickname)
; CREATE INDEX idx_assignment_repository_provisioning_initiator_fk
ON data.assignment_repository_provisioning USING btree (initiated_by_user_id)
; CREATE TRIGGER tg_assignment_repository_provisioning_update_timestamps BEFORE INSERT OR UPDATE ON data.assignment_repository_provisioning FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column()
; COMMENT ON TABLE data.assignment_repository_provisioning IS 'An attempt to provision a forge repository for a student or team from a template, from the click to the finalized repository row'
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
; CREATE VIEW api.repository_provisionings AS
    SELECT *
    FROM data.assignment_repository_provisioning
; ALTER VIEW api.repository_provisionings
    OWNER TO api
; GRANT select ON api.repository_provisionings TO student, ta, faculty
; COMMENT ON VIEW api.repository_provisionings IS 'Repository provisioning attempts: one per student or team per template, with the stage the attempt has reached. Read-only; the authapp service advances it'
; COMMENT ON COLUMN api.repository_provisionings.id IS 'Surrogate key for this attempt'
; COMMENT ON COLUMN api.repository_provisionings.template_slug IS 'The template the repository is being created from'
; COMMENT ON COLUMN api.repository_provisionings.assignment_slug IS 'The assignment the template served when the attempt was claimed, NULL when none. The repository is recorded under it'
; COMMENT ON COLUMN api.repository_provisionings.is_team IS 'True when the repository will belong to a team, copied from the template'
; COMMENT ON COLUMN api.repository_provisionings.user_id IS 'Owning student, set when the template is individual and NULL otherwise'
; COMMENT ON COLUMN api.repository_provisionings.team_nickname IS 'Owning team, set when the template is a team template and NULL otherwise'
; COMMENT ON COLUMN api.repository_provisionings.initiated_by_user_id IS 'The student who started the attempt; for a team, one of its members'
; COMMENT ON COLUMN api.repository_provisionings.provider IS 'Forge the repository is created on, copied from the template when the attempt was claimed'
; COMMENT ON COLUMN api.repository_provisionings.template_full_name IS 'Template repository as owner/repo, copied from the template when the attempt was claimed'
; COMMENT ON COLUMN api.repository_provisionings.destination_name IS 'Name of the repository to create, without its organization: template slug and GitHub login or team nickname'
; COMMENT ON COLUMN api.repository_provisionings.provider_repo_id IS 'Forge repository id, NULL until the forge has returned one'
; COMMENT ON COLUMN api.repository_provisionings.provider_full_name IS 'Forge repository name such as org/repo, NULL until the forge has returned one'
; COMMENT ON COLUMN api.repository_provisionings.stage IS 'How far the attempt has got: claimed, generated, granted, finalized or failed'
; COMMENT ON COLUMN api.repository_provisionings.error_code IS 'Stable code for why the attempt failed, NULL otherwise. Never a raw forge message'
; COMMENT ON COLUMN api.repository_provisionings.last_checked_at IS 'When the service last asked the forge whether the repository contents were ready'
; COMMENT ON COLUMN api.repository_provisionings.ready_at IS 'When the forge first reported the repository contents ready, NULL until then'
; COMMENT ON COLUMN api.repository_provisionings.created_at IS 'When the attempt was claimed'
; COMMENT ON COLUMN api.repository_provisionings.updated_at IS 'When the attempt last changed'
;
-- The assignment trigger, now that both tables it reads exist.
CREATE TRIGGER tg_assignment_repository_assignment BEFORE INSERT OR UPDATE ON data.assignment_repository FOR EACH ROW EXECUTE FUNCTION data.keep_assignment_repository_assignment()
;
-- ---------------------------------------------------------------------------
-- api.users carries the identity
-- ---------------------------------------------------------------------------
-- Read-only. The existing policy on data."user" shows a student their own
-- row, and a TA or faculty every row; the authapp service reads it to render
-- a profile. Faculty held INSERT and UPDATE on the whole view, which would
-- have made a PATCH of github_verified_at a way to forge a verification.
-- Their write privilege is restated column by column over the columns they
-- had, so the three new ones are reachable only through
-- api.set_user_github_identity and api.import_github_logins.
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
-- Claim, or resume, an attempt for a student on a template. Returns the
-- attempt row plus existing_repository_id, which is NULL unless a repository
-- already exists for the owner and template, in which case the row is
-- synthesized from it (stage finalized) and no attempt is created or
-- changed. That covers both a student coming back after a successful
-- provisioning and a repository the old course tooling created.
CREATE FUNCTION api.claim_repository_provisioning(p_template_slug text, p_user_id int) RETURNS TABLE (id int, template_slug text, assignment_slug text, is_team boolean, user_id int, team_nickname text, initiated_by_user_id int, provider text, template_full_name text, destination_name text, provider_repo_id bigint, provider_full_name text, stage text, error_code text, last_checked_at timestamp with time zone, ready_at timestamp with time zone, created_at timestamp with time zone, updated_at timestamp with time zone, existing_repository_id int) SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    the_template data.repository_template%ROWTYPE;
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

    SELECT t.* INTO the_template FROM data.repository_template t WHERE t.slug = p_template_slug;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'template_not_found',
            DETAIL = format('no repository template %s', p_template_slug);
    END IF;
    IF NOT the_template.is_active THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'template_inactive',
            DETAIL = format('repository template %s is not active', p_template_slug);
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

    IF the_template.is_team THEN
        IF the_user.team_nickname IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001',
                MESSAGE = 'no_team',
                DETAIL = format('%s is a team template and user %s is on no team', p_template_slug, p_user_id);
        END IF;
        owner_team := the_user.team_nickname;
    ELSE
        owner_user := p_user_id;
    END IF;

    -- Two clicks in flight for the same owner serialize here, so the second
    -- resumes the attempt the first created instead of tripping the unique
    -- index.
    PERFORM pg_advisory_xact_lock(hashtext('repository_provisioning:' || p_template_slug || ':' || coalesce(owner_team, owner_user::text)));

    SELECT r.* INTO the_repository
    FROM data.assignment_repository r
    WHERE r.template_slug = p_template_slug
      AND r.user_id IS NOT DISTINCT FROM owner_user
      AND r.team_nickname IS NOT DISTINCT FROM owner_team;

    SELECT p.* INTO the_attempt
    FROM data.assignment_repository_provisioning p
    WHERE p.template_slug = p_template_slug
      AND p.user_id IS NOT DISTINCT FROM owner_user
      AND p.team_nickname IS NOT DISTINCT FROM owner_team
    FOR UPDATE;

    IF the_repository.id IS NOT NULL THEN
        -- The attempt's id is carried when there is one, so readiness can
        -- still be recorded against it; the rest describes the repository.
        RETURN QUERY SELECT
            the_attempt.id, the_repository.template_slug, the_repository.assignment_slug, the_repository.is_team,
            the_repository.user_id, the_repository.team_nickname, p_user_id,
            the_repository.provider, the_template.template_full_name,
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
            the_attempt.id, the_attempt.template_slug, the_attempt.assignment_slug, the_attempt.is_team,
            the_attempt.user_id, the_attempt.team_nickname, the_attempt.initiated_by_user_id,
            the_attempt.provider, the_attempt.template_full_name, the_attempt.destination_name,
            the_attempt.provider_repo_id, the_attempt.provider_full_name,
            the_attempt.stage, the_attempt.error_code, the_attempt.last_checked_at, the_attempt.ready_at,
            the_attempt.created_at, the_attempt.updated_at, NULL::int;
        RETURN;
    END IF;

    -- A fresh attempt from a template that serves an assignment needs that
    -- assignment open for this owner: published, and before the later of
    -- its deadline and the owner's extension, the same rule
    -- data.assignment_field_submission_is_writable_by_current_user applies
    -- to the submission itself. A template tied to no assignment is always
    -- open.
    IF the_template.assignment_slug IS NOT NULL THEN
        SELECT a.* INTO the_assignment FROM data.assignment a WHERE a.slug = the_template.assignment_slug;
        SELECT GREATEST(the_assignment.closed_at, max(ge.closed_at)) INTO effective_closed_at
        FROM data.assignment_grade_exception ge
        WHERE ge.assignment_slug = the_template.assignment_slug
          AND ge.user_id IS NOT DISTINCT FROM owner_user
          AND ge.team_nickname IS NOT DISTINCT FROM owner_team;
        IF the_assignment.is_draft OR current_timestamp >= effective_closed_at THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001',
                MESSAGE = 'assignment_closed',
                DETAIL = CASE
                    WHEN the_assignment.is_draft THEN format('%s is a draft', the_template.assignment_slug)
                    ELSE format('%s closed for this owner at %s', the_template.assignment_slug, effective_closed_at)
                END;
        END IF;
    END IF;

    IF NOT the_template.is_team AND the_user.github_login IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'needs_github_link',
            DETAIL = format('user %s has no GitHub login on record', p_user_id);
    END IF;

    -- GitHub caps a repository name at 100 characters, which the table's CHECK
    -- restates. A legal slug plus a legal login or team nickname can exceed
    -- it, and that is a configuration problem to name, not a CHECK to trip.
    destination := p_template_slug || '-' || coalesce(owner_team, the_user.github_login);
    IF char_length(destination) > 100 THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'destination_name_too_long',
            DETAIL = format('%s is %s characters; the forge allows 100', destination, char_length(destination));
    END IF;

    INSERT INTO data.assignment_repository_provisioning (
        template_slug, assignment_slug, is_team, user_id, team_nickname, initiated_by_user_id,
        provider, template_full_name, destination_name, stage
    )
    VALUES (
        p_template_slug, the_template.assignment_slug, the_template.is_team, owner_user, owner_team, p_user_id,
        the_template.provider, the_template.template_full_name,
        destination, 'claimed'
    )
    RETURNING * INTO the_attempt;

    RETURN QUERY SELECT
        the_attempt.id, the_attempt.template_slug, the_attempt.assignment_slug, the_attempt.is_team,
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
; COMMENT ON FUNCTION api.claim_repository_provisioning(text, int) IS 'Claim or resume the repository provisioning attempt for a user on a template. authapp only. Returns the attempt, or a finalized row synthesized from an existing repository with existing_repository_id set. Refuses with template_not_found, template_inactive, not_a_student, no_team, assignment_closed, needs_github_link or destination_name_too_long.'
;
-- Record what the forge said. Transitions are forward only: claimed to
-- generated, generated to granted, anything not finalized to failed, and the
-- same stage again as a harmless repeat. A finalized attempt never changes.
CREATE FUNCTION api.record_repository_provisioning(p_attempt_id int, p_stage text, p_provider_repo_id bigint = NULL, p_provider_full_name text = NULL, p_error_code text = NULL) RETURNS SETOF api.repository_provisionings SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
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
-- Finalize: the repository row, and nothing else. Requires stage granted.
-- The deadline is deliberately not checked here: the attempt was claimed
-- while open, and an attempt that the forge finished after the deadline
-- still belongs to the student. No submission and no field submission are
-- written; the student hands the URL in themselves.
--
-- A finalized attempt finalizes again as a no-op that returns the repository
-- row: authapp cannot tell a lost response from a failed call, and the retry
-- has to be safe.
CREATE FUNCTION api.finalize_repository_provisioning(p_attempt_id int, p_provider_user_id bigint = NULL) RETURNS SETOF api.assignment_repositories SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    the_attempt data.assignment_repository_provisioning%ROWTYPE;
    the_repository data.assignment_repository%ROWTYPE;
    owner_github_user_id bigint;
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
        WHERE r.template_slug = the_attempt.template_slug
          AND r.user_id IS NOT DISTINCT FROM the_attempt.user_id
          AND r.team_nickname IS NOT DISTINCT FROM the_attempt.team_nickname;
        RETURN;
    END IF;

    IF the_attempt.stage <> 'granted' THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001',
            MESSAGE = 'invalid_stage_transition',
            DETAIL = format('attempt %s is at stage %s and only a granted attempt can be finalized', p_attempt_id, the_attempt.stage);
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

    -- An existing row for this owner and template is reused when it is the
    -- same repository; a different one is a conflict for staff, never an
    -- overwrite. The repository is recorded under the assignment the attempt
    -- was claimed for, not the template's current one. The unique indexes
    -- have the last word: the same forge repository recorded for another
    -- owner, or a row for this owner that landed between the read above and
    -- the insert, arrives as a unique violation, which is re-read and
    -- reported as the same conflict rather than as a bare 23505.
    SELECT r.* INTO the_repository
    FROM data.assignment_repository r
    WHERE r.template_slug = the_attempt.template_slug
      AND r.user_id IS NOT DISTINCT FROM the_attempt.user_id
      AND r.team_nickname IS NOT DISTINCT FROM the_attempt.team_nickname;
    IF FOUND THEN
        IF the_repository.provider <> the_attempt.provider OR the_repository.provider_repo_id <> the_attempt.provider_repo_id THEN
            RAISE EXCEPTION USING ERRCODE = 'P0001',
                MESSAGE = 'repository_conflict',
                DETAIL = format('a different repository (%s %s) is already recorded for this owner on template %s', the_repository.provider, the_repository.provider_repo_id, the_attempt.template_slug);
        END IF;
    ELSE
        BEGIN
            INSERT INTO data.assignment_repository (
                template_slug, assignment_slug, is_team, user_id, team_nickname,
                provider, provider_repo_id, provider_full_name, provider_user_id
            )
            VALUES (
                the_attempt.template_slug, the_attempt.assignment_slug, the_attempt.is_team, the_attempt.user_id, the_attempt.team_nickname,
                the_attempt.provider, the_attempt.provider_repo_id, the_attempt.provider_full_name, p_provider_user_id
            )
            RETURNING * INTO the_repository;
        EXCEPTION WHEN unique_violation THEN
            SELECT r.* INTO the_repository
            FROM data.assignment_repository r
            WHERE r.template_slug = the_attempt.template_slug
              AND r.user_id IS NOT DISTINCT FROM the_attempt.user_id
              AND r.team_nickname IS NOT DISTINCT FROM the_attempt.team_nickname;
            IF NOT FOUND OR the_repository.provider <> the_attempt.provider OR the_repository.provider_repo_id <> the_attempt.provider_repo_id THEN
                RAISE EXCEPTION USING ERRCODE = 'P0001',
                    MESSAGE = 'repository_conflict',
                    DETAIL = format('repository %s %s is already recorded for another owner, or this owner already holds a different one on template %s', the_attempt.provider, the_attempt.provider_repo_id, the_attempt.template_slug);
            END IF;
        END;
    END IF;

    UPDATE data.assignment_repository_provisioning p
    SET stage = 'finalized', error_code = NULL
    WHERE p.id = p_attempt_id;

    RETURN QUERY SELECT r.* FROM data.assignment_repository r WHERE r.id = the_repository.id;
END;
$$
; ALTER FUNCTION api.finalize_repository_provisioning(int, bigint) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.finalize_repository_provisioning(int, bigint) FROM public
; GRANT execute ON FUNCTION api.finalize_repository_provisioning(int, bigint) TO app
; COMMENT ON FUNCTION api.finalize_repository_provisioning(int, bigint) IS 'Finish a granted provisioning attempt: record the repository for its owner and template, under the assignment the attempt was claimed for, and mark the attempt finalized. Writes no submission. authapp only. Idempotent once finalized. Refuses with invalid_stage_transition, github_identity_mismatch or repository_conflict.'
;
-- Readiness, for the poll that waits for the template contents to land
-- (#396). ready_at is set once and never moved.
CREATE FUNCTION api.touch_repository_provisioning_readiness(p_attempt_id int, p_ready boolean) RETURNS SETOF api.repository_provisionings SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
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
-- Shape 8: api.repository_templates, api.repository_provisionings and
-- api.my_repositories; template_slug appended to api.assignment_repositories
-- (and assignment_slug nullable there); the GitHub columns appended to
-- api.users. admin_api_version 15: the six RPCs above. Set membership for
-- the shape, a floor for the RPCs -- see docs/platform-compatibility.md.
CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::int AS platform_compatibility_version,
        8::int AS schema_compatibility_version, 15::int AS admin_api_version
; ALTER VIEW api.platform_version
    OWNER TO api
;
-- PostgREST caches the schema; without this it keeps serving without the new
-- views, columns and RPCs.
NOTIFY pgrst, 'reload schema'
