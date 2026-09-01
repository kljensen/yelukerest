-- Record how a field submission came to exist: an immutable `origin`
-- (issue #370).
--
-- `admin provision-repos` now writes a student's `repo-url` field submission
-- for them, so the platform submits graded work on a student's behalf and
-- nothing in the schema records that it did.
--
-- The columns that look like they answer this do not.
-- `assignment_field_submission.submitter_user_id` is `NOT NULL REFERENCES
-- "user"(id)`, so it can only ever name a person, and the defaults trigger
-- reassigns it to `request.user_id()` on UPDATE as well as INSERT: the first
-- time a student edits an auto-populated URL through PostgREST the live row
-- names the student and the provisioner is gone from it. The append-only
-- history keeps the provisioner on the original `submitted` event, but with
-- `created_by_user_id` NULL -- and that NULL means "not written through the
-- API", not "auto-populated". A psql repair, a migration, and a loader are
-- indistinguishable from provisioning under it. Reading business meaning off a
-- connection mode is the thing this column removes.
--
-- TEXT + CHECK rather than an enum, matching the local convention:
-- `assignment_field_submission_event.event_type` and `.operation` are checked
-- text, while enums here are reserved for intrinsically stable domains such as
-- `user_role`. Adding a value to a CHECK later is an ordinary reversible
-- constraint replacement; removing or renaming an enum label tends to make a
-- migration irreversible, and this taxonomy will evolve.
--
-- Named `origin` rather than `source` because `grade_event.source` already
-- means producer identity in this schema (`api.import_assignment_grades`).
-- Two columns named `source` meaning "which function wrote this" and "what
-- kind of act was this" would be a trap.

-- ---------------------------------------------------------------------------
-- The columns.
-- ---------------------------------------------------------------------------
--
-- Added WITH a default and then stripped of it. The default exists only to
-- backfill the rows already in the table, and it must not survive: a default
-- would let a direct writer that says nothing about provenance succeed
-- silently, which is exactly the ambiguity the column exists to remove. After
-- this migration a write with no request identity must state its origin or be
-- refused.
--
-- ADD COLUMN ... DEFAULT is the backfill on purpose. An UPDATE would fire the
-- row triggers on this table and append a `revised` event per row, writing a
-- term of fictional revision history that never happened.
--
-- The backfill value is 'migration' for every existing row, in both tables.
-- Production holds zero `repo-url` submissions, so nothing provisioned is
-- being mislabelled; development and any other environment hold submissions
-- whose true origin is not recoverable -- see the issue on why guessing it
-- from bodies and NULL actors would manufacture the fiction this column is
-- meant to prevent. 'migration' says "this row predates the question", which
-- is the only true thing available.

ALTER TABLE data.assignment_field_submission
    ADD COLUMN origin TEXT NOT NULL DEFAULT 'migration';

ALTER TABLE data.assignment_field_submission
    ALTER COLUMN origin DROP DEFAULT;

ALTER TABLE data.assignment_field_submission
    ADD CONSTRAINT origin_is_known
    CHECK (origin IN ('student', 'provisioning', 'import', 'staff', 'migration'));

COMMENT ON COLUMN data.assignment_field_submission.origin IS
    'How this field submission first came to exist. Set once by tg_assignment_field_submission_default and never changed. Issue #370.';

ALTER TABLE data.assignment_field_submission_event
    ADD COLUMN origin TEXT NOT NULL DEFAULT 'migration';

ALTER TABLE data.assignment_field_submission_event
    ALTER COLUMN origin DROP DEFAULT;

ALTER TABLE data.assignment_field_submission_event
    ADD CONSTRAINT origin_is_known
    CHECK (origin IN ('student', 'provisioning', 'import', 'staff', 'migration'));

COMMENT ON COLUMN data.assignment_field_submission_event.origin IS
    'Origin copied from the submission row this event describes. Never decided independently. Issue #370.';

-- ---------------------------------------------------------------------------
-- The defaults trigger, which is the only enforcement.
-- ---------------------------------------------------------------------------
--
-- Grants on this table are table-wide, not column-scoped: `student` and `ta`
-- hold INSERT and UPDATE on api.assignment_field_submissions as a whole, so
-- once the column exists they can name it in a payload. Nothing but this
-- function stops a student setting origin = 'provisioning' on their own work,
-- or flipping an auto-populated row to 'student'. tests/db/yeluke-field-
-- submission-origin.sql exercises both.
--
-- The body below is the function as
-- 01a01073-roadmap-9-admin-api left it -- including the `data.touched_at`
-- timestamp line from #308, which db/src still predates -- with one block
-- added. Nothing else changes.
CREATE OR REPLACE FUNCTION data.fill_assignment_field_submission_defaults()
RETURNS TRIGGER AS $$
DECLARE
    -- The origin the request identity implies, or NULL when the identity does
    -- not imply one. See the origin block below.
    classified_origin TEXT;
BEGIN
    -- Fill in the assignment_slug if it is NULL by looking
    -- at the assignment_slug from the assignment_submission.
    IF (NEW.assignment_slug IS NULL AND NEW.assignment_submission_id IS NOT NULL) THEN
        SELECT assignment_slug INTO NEW.assignment_slug
        FROM data.assignment_submission
        WHERE id = NEW.assignment_submission_id;
    END IF;
    -- Fill in the assignment_submission_id if it is null
    -- by looking at the assignment if the assignment_slug
    -- is not null.
    IF (NEW.assignment_submission_id IS NULL and NEW.assignment_slug IS NOT NULL and request.user_id() IS NOT NULL) THEN
        SELECT ass.id INTO NEW.assignment_submission_id
        FROM
            (data.assignment_submission ass
            LEFT OUTER JOIN data."user" u
            ON u.team_nickname = ass.team_nickname)
        WHERE (
            -- It is the right assignment
            assignment_slug = NEW.assignment_slug
            AND
            -- It is theirs or their teams assignment submission
            (u.id = request.user_id() OR user_id = request.user_id())
        );
    END IF;

    -- Try to fill in the `submitter_user_id`
    IF (request.user_id() IS NULL ) THEN
        IF (NEW.submitter_user_id IS NULL ) THEN
            -- In practice this should only be the case when an
            -- administrator is using the database directly and
            -- not through the API.
            SELECT submitter_user_id INTO NEW.submitter_user_id
            FROM data.assignment_submission AS sub
            WHERE sub.id = NEW.assignment_submission_id;
        END IF;
    ELSE
        NEW.submitter_user_id = request.user_id();
    END IF;

    -- `origin` records how the row came to exist, and never changes (#370).
    --
    -- What `origin` can and cannot prove. It records the *kind of request*
    -- that created the row, and nothing stronger. `origin = 'student'` means
    -- "created by a request bearing that student's identity" -- it does not
    -- prove the student was the person at the keyboard. Faculty can select
    -- api.user_jwts and receive a signed JWT for any non-observer user
    -- (db/src/api/yeluke/user_jwt.sql), so faculty writing through a student's
    -- JWT produces a genuine student request that this trigger classifies, and
    -- must classify, as `student`. No column on this table can see past that:
    -- the database is being told, truthfully, that a student request arrived.
    -- Closing the gap needs an actor or delegation claim in the JWT itself,
    -- which is an auth-layer change, not a trigger change. Our provisioning
    -- path does not impersonate -- `admin provision-repos` writes directly with
    -- an explicit `origin = 'provisioning'`, which is exactly why it is
    -- correctly labelled -- so this is a limit on how far the column may be
    -- trusted, not a hole in the mechanism it does implement.
    IF (TG_OP = 'UPDATE') THEN
        -- Unconditionally, whatever the payload says. A student revising an
        -- auto-populated URL leaves a provisioning-origin submission; that
        -- they revised it is already recorded by `submitter_user_id` and by
        -- the history event's `created_by_user_id`.
        NEW.origin := OLD.origin;
    ELSE
        -- An INSERT is classified only when the request identity is complete:
        -- a user id AND a role the schema recognises. A role the schema does
        -- not recognise -- including no role at all, which is what a direct
        -- session that sets only request.jwt.claim.user_id looks like -- is not
        -- a classifiable identity, and guessing one would be the same mistake
        -- as defaulting a no-identity write. Such a writer states its origin
        -- like any other direct writer, or is refused.
        classified_origin := CASE
            WHEN request.user_id() IS NULL THEN NULL
            WHEN request.user_role() = 'student' THEN 'student'
            WHEN request.user_role() IN ('ta', 'faculty') THEN 'staff'
            ELSE NULL
        END;

        IF (classified_origin IS NOT NULL) THEN
            -- Derived from the role, never from the payload, so naming
            -- `origin` in a POST or a PATCH achieves nothing.
            NEW.origin := classified_origin;
        ELSIF (NEW.origin IS NULL) THEN
            -- Deliberately not defaulted: defaulting an unclassifiable write to
            -- any one value recreates the psql/provisioning ambiguity this
            -- column exists to remove.
            RAISE EXCEPTION 'assignment_field_submission written without a classifiable request identity must state its origin'
                USING DETAIL = format(
                          'This write carries user id %s and role %s. Automatic classification needs both a user id and one of student, ta or faculty.',
                          coalesce(request.user_id_as_text(), '(none)'),
                          coalesce(request.user_role(), '(none)')),
                      HINT = 'Name origin explicitly: provisioning for admin provision-repos, import for a loader, migration for a backfill, student or staff for a repair made on someone''s behalf.';
        END IF;
    END IF;

    -- Try to fill in `pattern`
    IF (NEW.assignment_field_pattern is NULL) THEN
        SELECT pattern INTO NEW.assignment_field_pattern
        FROM data.assignment_field AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    -- Try to fill in `is_url`
    IF (NEW.assignment_field_is_url is NULL) THEN
        SELECT is_url INTO NEW.assignment_field_is_url
        FROM data.assignment_field AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    IF (TG_OP = 'UPDATE') THEN
        -- Optimistic concurrency: clients may include the `updated_at`
        -- they last read in an UPDATE. If it does not match the current
        -- row we reject the write as stale. Clients that omit
        -- `updated_at` skip this check (PostgREST leaves the old value
        -- in place for columns absent from the payload).
        IF (NEW.updated_at IS DISTINCT FROM OLD.updated_at) THEN
            RAISE EXCEPTION 'stale write rejected: submission last updated at %, client expected %', OLD.updated_at, NEW.updated_at
                USING ERRCODE = 'PT409',
                      DETAIL = 'The assignment field submission changed since it was last read.',
                      HINT = 'Re-fetch the submission and retry with its current updated_at.';
        END IF;
        -- `created_at` is immutable once the row exists.
        NEW.created_at = OLD.created_at;
    ELSE
        -- Prevent API clients from supplying a bogus `created_at`.
        -- Direct database loads (no request user) keep their values.
        IF (request.user_id() IS NOT NULL) THEN
            NEW.created_at = current_timestamp;
        ELSE
            NEW.created_at = COALESCE(NEW.created_at, current_timestamp);
        END IF;
    END IF;

    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;

ALTER FUNCTION data.fill_assignment_field_submission_defaults() OWNER TO yelukerest_migrator;

-- ---------------------------------------------------------------------------
-- The history trigger copies the origin; it does not decide one.
-- ---------------------------------------------------------------------------
--
-- Deciding independently would let the two tables disagree, and the whole
-- point of the column is that the submission row and its history tell the same
-- story. On DELETE `submission_row` is OLD, so the deleted event carries the
-- origin the row had.
CREATE OR REPLACE FUNCTION data.record_assignment_field_submission_event()
RETURNS TRIGGER AS $$
DECLARE
    submission_row data.assignment_field_submission%ROWTYPE;
    event_kind TEXT;
BEGIN
    IF (TG_OP = 'DELETE') THEN
        submission_row := OLD;
        event_kind := 'deleted';
    ELSE
        submission_row := NEW;
        IF (TG_OP = 'INSERT') THEN
            event_kind := 'submitted';
        ELSE
            event_kind := 'revised';
        END IF;
    END IF;

    INSERT INTO data.assignment_field_submission_event (
        event_type,
        operation,
        assignment_submission_id,
        assignment_field_slug,
        assignment_slug,
        body_sha256,
        body_length,
        submitter_user_id,
        submission_created_at,
        submission_updated_at,
        created_by_user_id,
        origin
    )
    VALUES (
        event_kind,
        lower(TG_OP),
        submission_row.assignment_submission_id,
        submission_row.assignment_field_slug,
        submission_row.assignment_slug,
        encode(public.digest(submission_row.body, 'sha256'), 'hex'),
        octet_length(submission_row.body),
        submission_row.submitter_user_id,
        submission_row.created_at,
        submission_row.updated_at,
        request.user_id(),
        submission_row.origin
    );

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;

ALTER FUNCTION data.record_assignment_field_submission_event() OWNER TO yelukerest_migrator;

-- ---------------------------------------------------------------------------
-- The api views have to be recreated to see the column.
-- ---------------------------------------------------------------------------
--
-- `create view ... as select *` expands its column list once, at creation
-- time, and stores the expansion. An existing view does not grow a column when
-- its base table does; re-running the same `select *` is what picks it up.
-- Safe as CREATE OR REPLACE because `origin` lands last in both tables, and
-- REPLACE only permits columns appended at the end.
--
-- Owner and grants are restated rather than assumed. CREATE OR REPLACE VIEW
-- keeps both, but the view being owned by `api` is what makes row-level
-- security apply at all, so it is worth saying out loud where the view is
-- redefined.
CREATE OR REPLACE VIEW api.assignment_field_submissions AS
    SELECT * FROM data.assignment_field_submission;

ALTER VIEW api.assignment_field_submissions OWNER TO api;
GRANT SELECT, INSERT, UPDATE ON api.assignment_field_submissions TO student, ta;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.assignment_field_submissions TO faculty;

CREATE OR REPLACE VIEW api.assignment_field_submission_events AS
    SELECT * FROM data.assignment_field_submission_event;

ALTER VIEW api.assignment_field_submission_events OWNER TO api;
GRANT SELECT ON api.assignment_field_submission_events TO faculty;

-- Every api view column must carry a comment; the bootstrap verify script and
-- tests/db/structure.sql both assert it.
COMMENT ON COLUMN api.assignment_field_submissions.origin IS
    'How this field submission came to exist: student, provisioning, import, staff or migration. Set on insert and immutable thereafter';
COMMENT ON COLUMN api.assignment_field_submission_events.origin IS
    'Origin of the field submission this event describes, copied from the submission row';

NOTIFY pgrst, 'reload schema';
