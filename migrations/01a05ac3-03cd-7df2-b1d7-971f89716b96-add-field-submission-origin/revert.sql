-- Revert add-field-submission-origin.
--
-- Reverting throws away provenance that cannot be reconstructed: after this
-- runs, an auto-populated `repo-url` submission and one a student pasted
-- themselves are again distinguishable only by inferring meaning from a NULL
-- `created_by_user_id` on the first history event, which means "not written
-- through the API" and not "auto-populated". This exists so the migration is
-- reversible, not as a routine operation.
--
-- Order matters: the api views are dropped before the columns they select, and
-- rebuilt after. The trigger functions are restored first so that no window
-- exists in which a trigger references a column that is going away.

-- ---------------------------------------------------------------------------
-- The trigger functions, as they were before this migration.
-- ---------------------------------------------------------------------------
--
-- fill_assignment_field_submission_defaults as
-- 01a01073-roadmap-9-admin-api left it. That version, not the one in db/src:
-- the two differ in the `updated_at` line, which #308 routed through
-- data.touched_at, and reverting to db/src here would silently undo that.
CREATE OR REPLACE FUNCTION data.fill_assignment_field_submission_defaults()
RETURNS TRIGGER AS $$
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

-- record_assignment_field_submission_event as the bootstrap left it: the
-- history INSERT without the origin column.
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
        created_by_user_id
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
        request.user_id()
    );

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;

ALTER FUNCTION data.record_assignment_field_submission_event() OWNER TO yelukerest_migrator;

-- ---------------------------------------------------------------------------
-- Drop the views, then the columns, then rebuild the views.
-- ---------------------------------------------------------------------------
--
-- CREATE OR REPLACE VIEW can append a column but cannot remove one, so these
-- have to go and come back. Nothing else in the schema selects from either
-- view -- no policy, function or other view -- so the drops are narrow.
-- Dropping a view discards its owner, grants and comments, so all three are
-- restated below.
DROP VIEW api.assignment_field_submissions;
DROP VIEW api.assignment_field_submission_events;

ALTER TABLE data.assignment_field_submission DROP COLUMN origin;
ALTER TABLE data.assignment_field_submission_event DROP COLUMN origin;

CREATE VIEW api.assignment_field_submissions AS
    SELECT * FROM data.assignment_field_submission;

ALTER VIEW api.assignment_field_submissions OWNER TO api;
GRANT SELECT, INSERT, UPDATE ON api.assignment_field_submissions TO student, ta;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.assignment_field_submissions TO faculty;

COMMENT ON VIEW api.assignment_field_submissions IS
    'Values submitted for individual assignment fields';
COMMENT ON COLUMN api.assignment_field_submissions.assignment_submission_id IS 'Submission this field value belongs to';
COMMENT ON COLUMN api.assignment_field_submissions.assignment_field_slug IS 'Assignment field this value answers';
COMMENT ON COLUMN api.assignment_field_submissions.assignment_slug IS 'Assignment this field value belongs to';
COMMENT ON COLUMN api.assignment_field_submissions.assignment_field_is_url IS 'Copied URL-validation setting for the field';
COMMENT ON COLUMN api.assignment_field_submissions.assignment_field_pattern IS 'Copied validation pattern for the field';
COMMENT ON COLUMN api.assignment_field_submissions.body IS 'Submitted field value';
COMMENT ON COLUMN api.assignment_field_submissions.submitter_user_id IS 'User who submitted this field value';
COMMENT ON COLUMN api.assignment_field_submissions.created_at IS 'When this field submission row was created';
COMMENT ON COLUMN api.assignment_field_submissions.updated_at IS 'When this field submission row was last updated';

CREATE VIEW api.assignment_field_submission_events AS
    SELECT * FROM data.assignment_field_submission_event;

ALTER VIEW api.assignment_field_submission_events OWNER TO api;
GRANT SELECT ON api.assignment_field_submission_events TO faculty;

COMMENT ON VIEW api.assignment_field_submission_events IS
    'Append-only history of assignment field submission inserts, updates, and deletions';
COMMENT ON COLUMN api.assignment_field_submission_events.id IS 'Unique assignment field submission history event id';
COMMENT ON COLUMN api.assignment_field_submission_events.event_type IS 'Submission event kind: submitted, revised, or deleted';
COMMENT ON COLUMN api.assignment_field_submission_events.operation IS 'Table operation that produced this event';
COMMENT ON COLUMN api.assignment_field_submission_events.assignment_submission_id IS 'Submission the affected field value belongs to';
COMMENT ON COLUMN api.assignment_field_submission_events.assignment_field_slug IS 'Assignment field the affected value answers';
COMMENT ON COLUMN api.assignment_field_submission_events.assignment_slug IS 'Assignment the affected field value belongs to';
COMMENT ON COLUMN api.assignment_field_submission_events.body_sha256 IS 'SHA-256 hash of the written field value';
COMMENT ON COLUMN api.assignment_field_submission_events.body_length IS 'Length in bytes of the written field value';
COMMENT ON COLUMN api.assignment_field_submission_events.submitter_user_id IS 'User recorded as the submitter of the field value';
COMMENT ON COLUMN api.assignment_field_submission_events.submission_created_at IS 'Field submission row creation timestamp captured for this event';
COMMENT ON COLUMN api.assignment_field_submission_events.submission_updated_at IS 'Field submission row update timestamp captured for this event';
COMMENT ON COLUMN api.assignment_field_submission_events.created_at IS 'When this history event was appended';
COMMENT ON COLUMN api.assignment_field_submission_events.created_by_user_id IS 'Request user that caused this history event, when available';

NOTIFY pgrst, 'reload schema';
