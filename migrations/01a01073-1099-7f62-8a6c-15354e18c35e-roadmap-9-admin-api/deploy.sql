-- Roadmap 9: the admin API surface, plus the online-quiz removal.
--
-- This work was authored against db/src while that was still the deployment
-- source. It is not any more -- CLAUDE.md: "db/src/ is the immutable-bootstrap
-- input and test fixtures. Do not add deployable schema changes there." So the
-- schema arrives here instead, as one forward migration on top of the
-- immutable bootstrap.
--
-- Contents, and the issue each came from:
--   #299  api.import_assignment_grades, data.resolve_assignment_grade_import,
--         data.team_submission_participation
--   #300  api.import_quiz_results, data.resolve_quiz_result_import, and the
--         attendance promotion that the old loaders never performed
--   #301  api.grant_assignment_extension and its two data-schema helpers
--   #302  the quiz extension removed rather than added: data.quiz_grade_exception
--         had no readers at all, so granting one changed nothing a student could do
--   #308  data.touched_at, and the eleven updated_at triggers routed through it
--   plus  the online-quiz remnants: quiz.is_offline and quiz.duration
--
-- Zapadka owns the transaction, so there is no BEGIN/COMMIT here.

-- ---------------------------------------------------------------------------
-- Row timestamps (#308)
-- ---------------------------------------------------------------------------
-- The timestamp to stamp on a row that is being changed now.
--
-- Every table with an `updated_at` also carries
-- `CHECK (updated_at >= created_at)`, and the obvious implementation --
-- `NEW.updated_at = current_timestamp` -- can violate it. `current_timestamp`
-- is *transaction start*, not statement time. So a transaction that updates a
-- row created by a transaction which started later writes an `updated_at`
-- earlier than that row's `created_at`, and the CHECK rejects it:
--
--     ERROR: new row for relation "assignment_grade_exception" violates check
--            constraint "updated_after_created"
--     DETAIL: ... created_at 05:21:53.415842, updated_at 05:21:53.079110
--
-- Two concurrent writes to one row, where the second transaction opened first,
-- are enough. It surfaces as a 500 rather than as quiet corruption, but it is a
-- 500 a faculty member hits while granting an extension or importing grades.
--
-- `GREATEST` is used rather than `clock_timestamp()` on purpose. Both close the
-- hole, but `clock_timestamp()` advances during a transaction, so a fresh
-- insert would get `updated_at > created_at` and every row would look edited
-- the moment it was created. `GREATEST(current_timestamp, ...)` leaves the
-- ordinary case byte-identical to the old behaviour -- on insert both columns
-- are `current_timestamp`, so they stay equal -- and differs only in the
-- pathological case it exists to fix.
--
-- `prior_updated_at` exists because `updated_at` is not only a record of when a
-- row changed -- on `assignment_field_submission` it is also the optimistic
-- concurrency token. A client sends back the `updated_at` it last read, and the
-- trigger rejects the write if it no longer matches. A token that fails to
-- advance is therefore worse than a wrong timestamp: a client holding the
-- pre-update value would pass the staleness check and silently overwrite
-- somebody else's concurrent change.
--
-- Clamping alone can do exactly that. On insert `updated_at` equals
-- `created_at`, so an update that clamps back up to `created_at` returns the
-- value already stored and the token stands still. Passing the previous value
-- and stepping one microsecond past it -- the resolution of `timestamptz` --
-- guarantees a strict advance while keeping the result equal to
-- `current_timestamp` in the ordinary case, since that is already the greatest.
--
-- This also closes a smaller pre-existing hole: two updates inside one
-- transaction used to receive the same token, because `current_timestamp` does
-- not move within a transaction.
--
-- `GREATEST` ignores NULLs, so callers on INSERT simply omit the argument.
--
-- Takes its inputs rather than reading them, so it works for callers whose row
-- variable is not named `NEW`.
CREATE OR REPLACE FUNCTION data.touched_at(
    row_created_at TIMESTAMP WITH TIME ZONE,
    prior_updated_at TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS TIMESTAMP WITH TIME ZONE AS $$
    SELECT GREATEST(
        current_timestamp,
        row_created_at,
        prior_updated_at + interval '1 microsecond'
    );
$$ LANGUAGE sql STABLE;

-- If there is an `updated_at` column on the model, set it to the
-- current timestamp with timezone. This is used so that we know
-- when a row was last changed.
--
-- Function taken from https://gist.github.com/logrusorgru/82b002b8807253b2adef
CREATE OR REPLACE FUNCTION data.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- The ten per-table updated_at triggers, routed through data.touched_at (#308).
-- Only the timestamp line changes; the bodies are otherwise as deployed.
-- ---------------------------------------------------------------------------
SET search_path = data, public;

-- from db/src/data/yeluke/assignment_field_submission.sql
CREATE OR REPLACE FUNCTION fill_assignment_field_submission_defaults()
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

-- from db/src/data/yeluke/assignment_grade.sql
CREATE OR REPLACE FUNCTION fill_assignment_grade_defaults()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT ass_sub.assignment_slug INTO NEW.assignment_slug
        FROM data.assignment_submission AS ass_sub
        WHERE ass_sub.id = NEW.assignment_submission_id;
    END IF;
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM data.assignment
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;

-- from db/src/data/yeluke/assignment_grade_exception.sql
CREATE OR REPLACE FUNCTION fill_assignment_grade_exception_defaults()
RETURNS TRIGGER AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM data.assignment
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;

-- from db/src/data/yeluke/assignment_submission.sql
CREATE OR REPLACE FUNCTION fill_assignment_submission_defaults()
RETURNS TRIGGER AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM data.assignment
        WHERE slug = NEW.assignment_slug;
    END IF;
    -- Set default user_id from request credentials
    IF (NEW.user_id IS NULL AND NOT NEW.is_team ) THEN
        NEW.user_id = request.user_id();
    END IF;
    -- Set default submitter_user_id. This is done in 
    -- the table defaults, but we do it here so that
    -- we can fill in team nickname below.
    IF (NEW.submitter_user_id IS NULL ) THEN
        IF (request.user_id() IS NULL ) THEN
            IF (NEW.user_id IS NOT NULL) THEN
                NEW.submitter_user_id = NEW.user_id;
            END IF;
        ELSE
            NEW.submitter_user_id = request.user_id();
        END IF;
    END IF;
    -- Set default team_nickname from user table
    IF (NEW.is_team AND NEW.team_nickname IS NULL) THEN
        SELECT u.team_nickname INTO NEW.team_nickname
        FROM data."user" AS u
        WHERE u.id = NEW.submitter_user_id;
    END IF;
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;

-- from db/src/data/yeluke/grade.sql
CREATE OR REPLACE FUNCTION fill_grade_defaults()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- from db/src/data/yeluke/grade_snapshot.sql
CREATE OR REPLACE FUNCTION fill_grade_snapshot_defaults()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- from db/src/data/yeluke/quiz_grade.sql
CREATE OR REPLACE FUNCTION fill_quiz_grade_defaults()
RETURNS TRIGGER AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM data.quiz
        WHERE id = NEW.quiz_id;
    END IF;
    IF (NEW.user_id IS NULL and request.user_id() IS NOT NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;

-- from db/src/data/yeluke/quiz_submission.sql
CREATE OR REPLACE FUNCTION fill_quiz_submission_defaults()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.user_id IS NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- from db/src/data/yeluke/quiz.sql
CREATE OR REPLACE FUNCTION quiz_set_defaults() RETURNS trigger AS $$
BEGIN
  IF (NEW.closed_at IS NULL) THEN
    SELECT begins_at INTO NEW.closed_at
    FROM data.meeting
    WHERE slug = NEW.meeting_slug;
  END IF;
  IF (NEW.open_at IS NULL) THEN
    SELECT (begins_at - '5 days'::INTERVAL) INTO NEW.open_at
    FROM data.meeting
    WHERE slug = NEW.meeting_slug;
  END IF;
  NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
  RETURN NEW;
END; $$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;
-- from db/src/libs/auth/data/user.sql
CREATE OR REPLACE function clean_user_fields() returns trigger as $$
BEGIN
    NEW.email := lower(NEW.email);
    NEW.netid := lower(NEW.netid);
    NEW.nickname := lower(NEW.nickname);
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    return NEW;
END;
$$ language plpgsql;

-- ---------------------------------------------------------------------------
-- Grade history learns to name its writer (#299, #300).
-- An unset setting keeps the historical default, so no other writer changes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_assignment_grade_event()
RETURNS TRIGGER AS $$
DECLARE
    grade_row data.assignment_grade%ROWTYPE;
    event_kind TEXT;
BEGIN
    IF (TG_OP = 'DELETE') THEN
        grade_row := OLD;
        event_kind := 'voided';
    ELSE
        grade_row := NEW;
        IF (TG_OP = 'INSERT') THEN
            event_kind := 'recorded';
        ELSE
            event_kind := 'corrected';
        END IF;
    END IF;

    INSERT INTO data.assignment_grade_event (
        event_type,
        operation,
        assignment_submission_id,
        assignment_slug,
        points_possible,
        points,
        description,
        grade_created_at,
        grade_updated_at,
        created_by_user_id,
        source,
        reason,
        import_id
    )
    VALUES (
        event_kind,
        lower(TG_OP),
        grade_row.assignment_submission_id,
        grade_row.assignment_slug,
        grade_row.points_possible,
        grade_row.points,
        grade_row.description,
        grade_row.created_at,
        grade_row.updated_at,
        request.user_id(),
        COALESCE(
            nullif(current_setting('yeluke.grade_event_source', true), ''),
            'data.assignment_grade'
        ),
        nullif(current_setting('yeluke.grade_event_reason', true), ''),
        nullif(current_setting('yeluke.grade_event_import_id', true), '')
    );

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;

CREATE OR REPLACE FUNCTION record_quiz_grade_event()
RETURNS TRIGGER AS $$
DECLARE
    grade_row data.quiz_grade%ROWTYPE;
    event_kind TEXT;
BEGIN
    IF (TG_OP = 'DELETE') THEN
        grade_row := OLD;
        event_kind := 'voided';
    ELSE
        grade_row := NEW;
        IF (TG_OP = 'INSERT') THEN
            event_kind := 'recorded';
        ELSE
            event_kind := 'corrected';
        END IF;
    END IF;

    INSERT INTO data.quiz_grade_event (
        event_type,
        operation,
        quiz_id,
        user_id,
        points,
        points_possible,
        description,
        grade_created_at,
        grade_updated_at,
        created_by_user_id,
        source,
        reason,
        import_id
    )
    VALUES (
        event_kind,
        lower(TG_OP),
        grade_row.quiz_id,
        grade_row.user_id,
        grade_row.points,
        grade_row.points_possible,
        grade_row.description,
        grade_row.created_at,
        grade_row.updated_at,
        request.user_id(),
        COALESCE(
            nullif(current_setting('yeluke.grade_event_source', true), ''),
            'data.quiz_grade'
        ),
        nullif(current_setting('yeluke.grade_event_reason', true), ''),
        nullif(current_setting('yeluke.grade_event_import_id', true), '')
    );

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, pg_temp;

-- The insert-time participant snapshot (#299). Deliberately in `data`, not
-- `api`: PostgREST must not expose it, and faculty already see every
-- submission, so it grants no new visibility.
CREATE OR REPLACE VIEW team_submission_participation AS
    SELECT
        submission.assignment_slug,
        participant.user_id,
        participant.assignment_submission_id
    FROM assignment_submission_participant AS participant
    JOIN assignment_submission AS submission
        ON submission.id = participant.assignment_submission_id
    WHERE submission.is_team;

-- ---------------------------------------------------------------------------
-- The admin API surface (#299, #300, #301) and its data-schema helpers.
-- Taken verbatim from db/src as it stood before the cutover.
-- ---------------------------------------------------------------------------
SET search_path = api, public;

-- Resolve import rows to the submission each grade belongs on.
--
-- This lives in the data schema because PostgREST exposes only the api schema
-- and this is not an endpoint, but it is defined here because it reads the api
-- views. It is SECURITY INVOKER on purpose: the caller's own row visibility
-- applies, and a caller who cannot see a submission cannot grade it.
CREATE OR REPLACE FUNCTION data.resolve_assignment_grade_import(p_grades jsonb)
RETURNS TABLE (
    assignment_slug text,
    netid text,
    user_id integer,
    is_team boolean,
    team_nickname text,
    points_possible smallint,
    points real,
    has_description boolean,
    description text,
    assignment_submission_id integer
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        assignment.slug,
        student.netid,
        student.id,
        assignment.is_team,
        student.team_nickname,
        assignment.points_possible,
        (element.value->>'points')::real,
        element.value ? 'description',
        element.value->>'description',
        CASE
            WHEN assignment.is_team THEN team_submission.assignment_submission_id
            ELSE individual_submission.id
        END
    FROM jsonb_array_elements(p_grades) AS element(value)
    JOIN api.assignments assignment
        ON assignment.slug = btrim(element.value->>'assignment_slug')
    JOIN api.users student
        ON student.netid = lower(btrim(element.value->>'netid'))
    -- An individual submission belongs to exactly one student, so the student
    -- identifies it.
    LEFT JOIN api.assignment_submissions individual_submission
        ON NOT assignment.is_team
        AND individual_submission.assignment_slug = assignment.slug
        AND individual_submission.user_id = student.id
    -- A team submission is found through the insert-time participant snapshot,
    -- never through the student's current team. Rosters change mid-term, and a
    -- student who moved teams must still be graded on the work they did rather
    -- than on their new team's work. data.assignment_submission_participant is
    -- the only record of which is which.
    LEFT JOIN data.team_submission_participation team_submission
        ON assignment.is_team
        AND team_submission.assignment_slug = assignment.slug
        AND team_submission.user_id = student.id;
$$;

REVOKE ALL ON FUNCTION data.resolve_assignment_grade_import(jsonb) FROM PUBLIC;

-- Import final assignment grades keyed on assignment_slug + netid.
--
-- The payload carries final, absolute points. This function never derives a
-- curve denominator from the payload: a batch-relative maximum makes the same
-- raw score mean different things depending on which rows happened to be in the
-- file, and a makeup exam sat by a single student would score 100% by
-- construction. Curving belongs to the client, which knows the full cohort.
--
-- Everything is re-runnable. A second run of the same payload writes nothing
-- and reports every row as unchanged, so no redundant 'corrected' rows land in
-- data.assignment_grade_event.
CREATE OR REPLACE FUNCTION import_assignment_grades(
    p_grades jsonb,
    p_create_missing_submissions boolean DEFAULT true,
    p_dry_run boolean DEFAULT false,
    p_import_id text DEFAULT NULL,
    p_reason text DEFAULT NULL
)
RETURNS TABLE (
    inserted_count integer,
    updated_count integer,
    unchanged_count integer,
    submission_created_count integer,
    import_id text,
    dry_run boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    input_count integer;
    description_limit integer;
    offenders text;
BEGIN
    p_create_missing_submissions := COALESCE(p_create_missing_submissions, true);
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;
    import_id := COALESCE(nullif(btrim(p_import_id), ''), gen_random_uuid()::text);

    IF p_grades IS NULL OR jsonb_typeof(p_grades) <> 'array' THEN
        RAISE EXCEPTION 'import_assignment_grades expects a JSON array'
            USING ERRCODE = '22023';
    END IF;

    IF octet_length(p_grades::text) > 4194304 THEN
        RAISE EXCEPTION 'import_assignment_grades payload exceeds the 4 MB limit'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_grades);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'import_assignment_grades refuses to import an empty grade list'
            USING ERRCODE = '22023';
    END IF;

    IF input_count > 2000 THEN
        RAISE EXCEPTION 'import_assignment_grades accepts at most 2000 grades, received %', input_count
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_grades) AS element(value)
        WHERE jsonb_typeof(element.value) <> 'object'
    ) THEN
        RAISE EXCEPTION 'import_assignment_grades expects a JSON object for every grade'
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(position::text, ', ' ORDER BY position) INTO offenders
    FROM (
        SELECT element.position
        FROM jsonb_array_elements(p_grades)
            WITH ORDINALITY AS element(value, position)
        WHERE COALESCE(btrim(element.value->>'assignment_slug'), '') = ''
            OR COALESCE(btrim(element.value->>'netid'), '') = ''
    ) AS incomplete_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires assignment_slug and netid on every grade, missing at position: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- A missing score is not a zero. The CSV loader this replaces dropped such
    -- rows silently; refusing them makes the caller say which one they meant.
    SELECT string_agg(grade_key, ', ' ORDER BY grade_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'assignment_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS grade_key
        FROM jsonb_array_elements(p_grades) AS element(value)
        WHERE element.value->'points' IS NULL
            OR jsonb_typeof(element.value->'points') = 'null'
    ) AS scoreless_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires a points value on every grade, a missing or null score is not a zero: %', offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(grade_key, ', ' ORDER BY grade_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'assignment_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS grade_key
        FROM jsonb_array_elements(p_grades) AS element(value)
        WHERE jsonb_typeof(element.value->'points') <> 'number'
    ) AS non_numeric_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires numeric points: %', offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(grade_key, ', ' ORDER BY grade_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'assignment_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS grade_key
        FROM jsonb_array_elements(p_grades) AS element(value)
        GROUP BY 1
        HAVING count(*) > 1
    ) AS duplicate_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades received duplicate assignment_slug/netid key: %', offenders
            USING ERRCODE = '23505';
    END IF;

    SELECT string_agg(DISTINCT input_grade.assignment_slug, ', '
        ORDER BY input_grade.assignment_slug) INTO offenders
    FROM (
        SELECT btrim(element.value->>'assignment_slug') AS assignment_slug
        FROM jsonb_array_elements(p_grades) AS element(value)
    ) AS input_grade
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.assignments assignment
        WHERE assignment.slug = input_grade.assignment_slug
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades does not know assignment slug: %', offenders
            USING ERRCODE = '23503';
    END IF;

    -- The loader this replaces joined netids to users, so an unknown netid
    -- vanished and the run still reported success.
    SELECT string_agg(DISTINCT input_grade.netid, ', '
        ORDER BY input_grade.netid) INTO offenders
    FROM (
        SELECT lower(btrim(element.value->>'netid')) AS netid
        FROM jsonb_array_elements(p_grades) AS element(value)
    ) AS input_grade
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.users student
        WHERE student.netid = input_grade.netid
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades does not know netid: %', offenders
            USING ERRCODE = '23503';
    END IF;

    -- A student who moved teams mid-term can hold a participant row in two team
    -- submissions for one assignment. Which one the grade belongs to is a
    -- judgement no import can make, so say so rather than pick.
    SELECT string_agg(grade_key, ', ' ORDER BY grade_key) INTO offenders
    FROM (
        SELECT assignment.slug || '/' || student.netid AS grade_key
        FROM jsonb_array_elements(p_grades) AS element(value)
        JOIN api.assignments assignment
            ON assignment.slug = btrim(element.value->>'assignment_slug')
        JOIN api.users student
            ON student.netid = lower(btrim(element.value->>'netid'))
        JOIN data.team_submission_participation participation
            ON participation.assignment_slug = assignment.slug
            AND participation.user_id = student.id
        WHERE assignment.is_team
        GROUP BY 1
        HAVING count(*) > 1
    ) AS ambiguous_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades cannot tell which team submission belongs to these students, they took part in more than one: %', offenders
            USING ERRCODE = '23505';
    END IF;

    SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
        ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    WHERE resolved_grade.points < 0
        OR resolved_grade.points > resolved_grade.points_possible;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires points between 0 and the assignment points_possible, out of range for: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- Read the bound from the constraint rather than repeating the number here,
    -- so the two cannot drift. If the constraint is ever reshaped past this
    -- pattern the limit reads NULL, the comparison matches nothing, and the real
    -- write becomes the only check again; the test suite pins the shape.
    SELECT (regexp_match(
                pg_get_constraintdef(grade_constraint.oid),
                'octet_length\(description\) <= (\d+)'
            ))[1]::integer
    INTO description_limit
    FROM pg_constraint grade_constraint
    JOIN pg_class grade_table
        ON grade_table.oid = grade_constraint.conrelid
    JOIN pg_namespace grade_schema
        ON grade_schema.oid = grade_table.relnamespace
    WHERE grade_schema.nspname = 'data'
        AND grade_table.relname = 'assignment_grade'
        AND grade_constraint.contype = 'c'
        AND pg_get_constraintdef(grade_constraint.oid) LIKE '%octet_length(description)%';

    SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
        ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    WHERE resolved_grade.has_description
        AND octet_length(resolved_grade.description) > description_limit;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires a description of at most % bytes, too long for: %', description_limit, offenders
            USING ERRCODE = '22023';
    END IF;

    -- A team assignment has one submission per team, so two teammates in one
    -- payload are two keys pointing at one row. Rejecting that is the same rule
    -- as the duplicate key above, applied after the netids resolve.
    --
    -- The row does not have to exist yet. Two teammates whose team has never
    -- submitted both resolve to nothing, and would become two inserts against
    -- one unique (team_nickname, assignment_slug) index -- which is the ordinary
    -- shape of a team assignment graded from a per-student file. Keying on the
    -- submission when there is one and on the team it would be created for when
    -- there is not covers both with one rule, so a dry run cannot pass where the
    -- real write would fail.
    SELECT string_agg(target_key || ' (' || netids || ')', ', ' ORDER BY target_key)
        INTO offenders
    FROM (
        SELECT
            resolved_grade.assignment_slug || COALESCE(
                '#' || resolved_grade.assignment_submission_id::text,
                '@' || resolved_grade.team_nickname
            ) AS target_key,
            string_agg(resolved_grade.netid, ' + ' ORDER BY resolved_grade.netid) AS netids
        FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
        WHERE resolved_grade.assignment_submission_id IS NOT NULL
            OR (resolved_grade.is_team AND resolved_grade.team_nickname IS NOT NULL)
        GROUP BY 1
        HAVING count(*) > 1
    ) AS collapsed_submissions;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades received more than one netid for the same submission, send one row per team: %', offenders
            USING ERRCODE = '23505';
    END IF;

    -- Everything below concerns rows with no submission yet, where the current
    -- team_nickname is the only signal there is. That is right for a genuinely
    -- new submission and wrong for anything else, so the cases where it would
    -- be wrong are refused here rather than guessed at.
    SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
        ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    WHERE resolved_grade.is_team
        AND resolved_grade.assignment_submission_id IS NULL
        AND resolved_grade.team_nickname IS NULL;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades cannot create a team submission for a student with no team: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- The student joined their current team after it submitted, so they are not
    -- in its participant snapshot and a second submission for that team cannot
    -- exist. Grading them on work they are not recorded as having done is a
    -- decision for a person.
    SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
        ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    WHERE resolved_grade.is_team
        AND resolved_grade.assignment_submission_id IS NULL
        AND resolved_grade.team_nickname IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM api.assignment_submissions submission
            WHERE submission.assignment_slug = resolved_grade.assignment_slug
                AND submission.team_nickname = resolved_grade.team_nickname
        );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades will not grade these students on their current team submission, they did not take part in it: %', offenders
            USING ERRCODE = '22023';
    END IF;

    IF NOT p_create_missing_submissions THEN
        SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
            ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
        FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
        WHERE resolved_grade.assignment_submission_id IS NULL;

        IF offenders IS NOT NULL THEN
            RAISE EXCEPTION 'import_assignment_grades found no assignment submission for: %', offenders
                USING ERRCODE = '23503';
        END IF;
    END IF;

    SELECT
        count(*) FILTER (
            WHERE existing_grade.assignment_submission_id IS NULL
        )::integer,
        count(*) FILTER (
            WHERE existing_grade.assignment_submission_id IS NOT NULL
                AND (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                    resolved_grade.points,
                    CASE
                        WHEN resolved_grade.has_description THEN resolved_grade.description
                        ELSE existing_grade.description
                    END
                )
        )::integer,
        count(*) FILTER (
            WHERE existing_grade.assignment_submission_id IS NOT NULL
                AND NOT ((existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                    resolved_grade.points,
                    CASE
                        WHEN resolved_grade.has_description THEN resolved_grade.description
                        ELSE existing_grade.description
                    END
                ))
        )::integer,
        count(*) FILTER (
            WHERE resolved_grade.assignment_submission_id IS NULL
        )::integer
    INTO inserted_count, updated_count, unchanged_count, submission_created_count
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    LEFT JOIN api.assignment_grades existing_grade
        ON existing_grade.assignment_submission_id = resolved_grade.assignment_submission_id;

    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'import_assignment_grades accounted for % of % grades', inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_dry_run THEN
        RETURN NEXT;
        RETURN;
    END IF;

    PERFORM set_config('yeluke.grade_event_source', 'api.import_assignment_grades', true);
    PERFORM set_config('yeluke.grade_event_reason', COALESCE(p_reason, ''), true);
    PERFORM set_config('yeluke.grade_event_import_id', import_id, true);

    -- data.assignment_grade cannot exist without a submission to hang it on, and
    -- a paper exam never produces one, so an import that refuses to create them
    -- could never record a paper grade at all. The participant snapshot on a
    -- created team submission is the roster as of import time, which is the only
    -- roster the database has.
    --
    -- This runs unconditionally: when p_create_missing_submissions is false the
    -- check above has already failed the import, so there is nothing to create.
    WITH missing_submissions AS (
        SELECT
            resolved_grade.assignment_slug,
            resolved_grade.is_team,
            resolved_grade.user_id,
            -- The only case where the current team is the right team: there is
            -- no earlier submission to belong to, so this student's team now is
            -- the team doing the work now.
            resolved_grade.team_nickname
        FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
        WHERE resolved_grade.assignment_submission_id IS NULL
    ),
    created_submissions AS (
        INSERT INTO api.assignment_submissions (
            assignment_slug,
            is_team,
            user_id,
            team_nickname,
            submitter_user_id
        )
        SELECT
            missing_submission.assignment_slug,
            missing_submission.is_team,
            CASE WHEN missing_submission.is_team THEN NULL ELSE missing_submission.user_id END,
            CASE WHEN missing_submission.is_team THEN missing_submission.team_nickname ELSE NULL END,
            -- An individual submission must be submitted by its own owner, so
            -- the faculty importer cannot be the submitter here.
            missing_submission.user_id
        FROM missing_submissions missing_submission
        RETURNING id
    )
    SELECT count(*)::integer INTO submission_created_count
    FROM created_submissions;

    -- Re-resolving after the inserts above is what makes the newly created
    -- submissions visible, including their freshly snapshotted participants.
    WITH resolved_grades AS (
        SELECT *
        FROM data.resolve_assignment_grade_import(p_grades)
    ),
    updated_grades AS (
        UPDATE api.assignment_grades existing_grade
        SET
            points = resolved_grade.points,
            description = CASE
                WHEN resolved_grade.has_description THEN resolved_grade.description
                ELSE existing_grade.description
            END
        FROM resolved_grades resolved_grade
        WHERE existing_grade.assignment_submission_id = resolved_grade.assignment_submission_id
            AND (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                resolved_grade.points,
                CASE
                    WHEN resolved_grade.has_description THEN resolved_grade.description
                    ELSE existing_grade.description
                END
            )
        RETURNING existing_grade.assignment_submission_id
    ),
    inserted_grades AS (
        INSERT INTO api.assignment_grades (
            assignment_submission_id,
            assignment_slug,
            points_possible,
            points,
            description
        )
        SELECT
            resolved_grade.assignment_submission_id,
            resolved_grade.assignment_slug,
            resolved_grade.points_possible,
            resolved_grade.points,
            resolved_grade.description
        FROM resolved_grades resolved_grade
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.assignment_grades existing_grade
            WHERE existing_grade.assignment_submission_id = resolved_grade.assignment_submission_id
        )
        RETURNING assignment_submission_id
    )
    SELECT
        (SELECT count(*)::integer FROM updated_grades),
        (SELECT count(*)::integer FROM inserted_grades)
    INTO updated_count, inserted_count;

    PERFORM set_config('yeluke.grade_event_source', '', true);
    PERFORM set_config('yeluke.grade_event_reason', '', true);
    PERFORM set_config('yeluke.grade_event_import_id', '', true);

    -- Every payload row has to end up somewhere. The loader this replaces let
    -- rows fall out of an inner join and still reported success.
    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'import_assignment_grades wrote % of % grades', inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION import_assignment_grades(jsonb, boolean, boolean, text, text) FROM PUBLIC;

-- Resolve quiz import rows to the quiz, the student, and the two rows the
-- import may touch: the existing grade's submission and the existing
-- engagement.
--
-- Like data.resolve_assignment_grade_import this lives in the data schema
-- because PostgREST exposes only api, and it is SECURITY INVOKER on purpose so
-- that a caller who cannot see a quiz cannot grade it.
--
-- Resolution is exactly one-to-one in both directions: data.quiz.meeting_slug
-- is UNIQUE and data.user.netid is UNIQUE, so a meeting_slug/netid pair names
-- at most one quiz and one student. There is no team-submission ambiguity to
-- resolve here, which is why this is so much shorter than its assignment twin.
CREATE OR REPLACE FUNCTION data.resolve_quiz_result_import(p_results jsonb)
RETURNS TABLE (
    meeting_slug text,
    netid text,
    quiz_id integer,
    user_id integer,
    points_possible smallint,
    points real,
    has_description boolean,
    description text,
    has_submission boolean,
    participation data.participation_enum
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        quiz.meeting_slug,
        student.netid,
        quiz.id,
        student.id,
        quiz.points_possible,
        (element.value->>'points')::real,
        element.value ? 'description',
        element.value->>'description',
        existing_submission.quiz_id IS NOT NULL,
        existing_engagement.participation
    FROM jsonb_array_elements(p_results) AS element(value)
    JOIN api.quizzes quiz
        ON quiz.meeting_slug = btrim(element.value->>'meeting_slug')
    JOIN api.users student
        ON student.netid = lower(btrim(element.value->>'netid'))
    -- data.quiz_grade has a foreign key onto data.quiz_submission, so this is
    -- what says whether the grade has anything to hang on yet.
    LEFT JOIN api.quiz_submissions existing_submission
        ON existing_submission.quiz_id = quiz.id
        AND existing_submission.user_id = student.id
    -- NULL here means no engagement row at all, which is a different case from
    -- a row that says 'absent'.
    LEFT JOIN api.engagements existing_engagement
        ON existing_engagement.meeting_slug = quiz.meeting_slug
        AND existing_engagement.user_id = student.id;
$$;

REVOKE ALL ON FUNCTION data.resolve_quiz_result_import(jsonb) FROM PUBLIC;

-- Import paper quiz results keyed on meeting_slug + netid.
--
-- Named for the import rather than for the grades because it has a second
-- effect: p_mark_attended records that the people in the file were in the room.
-- That defaults to false so the side effect has to be asked for at the call
-- site rather than discovered afterwards.
--
-- As with api.import_assignment_grades the payload carries final, absolute
-- points. An OMR sheet's correct/total is turned into points client-side, where
-- the full cohort is known; a denominator derived from whichever rows happen to
-- be in one file makes the same raw score mean different things run to run.
--
-- Everything is re-runnable. A second run of the same payload writes nothing,
-- reports every row as unchanged, and appends no redundant 'corrected' rows to
-- data.quiz_grade_event.
CREATE OR REPLACE FUNCTION import_quiz_results(
    p_results jsonb,
    p_mark_attended boolean DEFAULT false,
    p_dry_run boolean DEFAULT false,
    p_import_id text DEFAULT NULL,
    p_reason text DEFAULT NULL
)
RETURNS TABLE (
    inserted_count integer,
    updated_count integer,
    unchanged_count integer,
    submission_created_count integer,
    attendance_inserted integer,
    attendance_updated integer,
    attendance_unchanged integer,
    import_id text,
    dry_run boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    input_count integer;
    description_limit integer;
    offenders text;
BEGIN
    p_mark_attended := COALESCE(p_mark_attended, false);
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;
    import_id := COALESCE(nullif(btrim(p_import_id), ''), gen_random_uuid()::text);

    IF p_results IS NULL OR jsonb_typeof(p_results) <> 'array' THEN
        RAISE EXCEPTION 'import_quiz_results expects a JSON array'
            USING ERRCODE = '22023';
    END IF;

    IF octet_length(p_results::text) > 4194304 THEN
        RAISE EXCEPTION 'import_quiz_results payload exceeds the 4 MB limit'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_results);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'import_quiz_results refuses to import an empty result list'
            USING ERRCODE = '22023';
    END IF;

    IF input_count > 2000 THEN
        RAISE EXCEPTION 'import_quiz_results accepts at most 2000 results, received %', input_count
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_results) AS element(value)
        WHERE jsonb_typeof(element.value) <> 'object'
    ) THEN
        RAISE EXCEPTION 'import_quiz_results expects a JSON object for every result'
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(position::text, ', ' ORDER BY position) INTO offenders
    FROM (
        SELECT element.position
        FROM jsonb_array_elements(p_results)
            WITH ORDINALITY AS element(value, position)
        WHERE COALESCE(btrim(element.value->>'meeting_slug'), '') = ''
            OR COALESCE(btrim(element.value->>'netid'), '') = ''
    ) AS incomplete_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires meeting_slug and netid on every result, missing at position: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- A blank cell on an answer sheet is a question no one answered, not a
    -- score of zero. The CSV loader this replaces dropped such rows silently.
    SELECT string_agg(result_key, ', ' ORDER BY result_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'meeting_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS result_key
        FROM jsonb_array_elements(p_results) AS element(value)
        WHERE element.value->'points' IS NULL
            OR jsonb_typeof(element.value->'points') = 'null'
    ) AS scoreless_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires a points value on every result, a missing or null score is not a zero: %', offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(result_key, ', ' ORDER BY result_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'meeting_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS result_key
        FROM jsonb_array_elements(p_results) AS element(value)
        WHERE jsonb_typeof(element.value->'points') <> 'number'
    ) AS non_numeric_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires numeric points: %', offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(result_key, ', ' ORDER BY result_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'meeting_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS result_key
        FROM jsonb_array_elements(p_results) AS element(value)
        GROUP BY 1
        HAVING count(*) > 1
    ) AS duplicate_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results received duplicate meeting_slug/netid key: %', offenders
            USING ERRCODE = '23505';
    END IF;

    -- Quizzes are keyed on the meeting they were sat in, so a meeting that
    -- exists but holds no quiz is just as unimportable as a meeting that does
    -- not exist. Both are named the same way.
    SELECT string_agg(DISTINCT input_result.meeting_slug, ', '
        ORDER BY input_result.meeting_slug) INTO offenders
    FROM (
        SELECT btrim(element.value->>'meeting_slug') AS meeting_slug
        FROM jsonb_array_elements(p_results) AS element(value)
    ) AS input_result
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.quizzes quiz
        WHERE quiz.meeting_slug = input_result.meeting_slug
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results does not know a quiz for meeting slug: %', offenders
            USING ERRCODE = '23503';
    END IF;

    -- The loader this replaces joined netids to users, so an unknown netid
    -- vanished and the run still reported success.
    SELECT string_agg(DISTINCT input_result.netid, ', '
        ORDER BY input_result.netid) INTO offenders
    FROM (
        SELECT lower(btrim(element.value->>'netid')) AS netid
        FROM jsonb_array_elements(p_results) AS element(value)
    ) AS input_result
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.users student
        WHERE student.netid = input_result.netid
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results does not know netid: %', offenders
            USING ERRCODE = '23503';
    END IF;

    SELECT string_agg(resolved_result.meeting_slug || '/' || resolved_result.netid, ', '
        ORDER BY resolved_result.meeting_slug || '/' || resolved_result.netid) INTO offenders
    FROM data.resolve_quiz_result_import(p_results) AS resolved_result
    WHERE resolved_result.points < 0
        OR resolved_result.points > resolved_result.points_possible;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires points between 0 and the quiz points_possible, out of range for: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- Read the bound from the constraint rather than repeating the number here,
    -- so the two cannot drift. If the constraint is ever reshaped past this
    -- pattern the limit reads NULL, the comparison matches nothing, and the real
    -- write becomes the only check again; the test suite pins the shape.
    SELECT (regexp_match(
                pg_get_constraintdef(grade_constraint.oid),
                'octet_length\(description\) <= (\d+)'
            ))[1]::integer
    INTO description_limit
    FROM pg_constraint grade_constraint
    JOIN pg_class grade_table
        ON grade_table.oid = grade_constraint.conrelid
    JOIN pg_namespace grade_schema
        ON grade_schema.oid = grade_table.relnamespace
    WHERE grade_schema.nspname = 'data'
        AND grade_table.relname = 'quiz_grade'
        AND grade_constraint.contype = 'c'
        AND pg_get_constraintdef(grade_constraint.oid) LIKE '%octet_length(description)%';

    SELECT string_agg(resolved_result.meeting_slug || '/' || resolved_result.netid, ', '
        ORDER BY resolved_result.meeting_slug || '/' || resolved_result.netid) INTO offenders
    FROM data.resolve_quiz_result_import(p_results) AS resolved_result
    WHERE resolved_result.has_description
        AND octet_length(resolved_result.description) > description_limit;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires a description of at most % bytes, too long for: %', description_limit, offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT
        count(*) FILTER (
            WHERE existing_grade.quiz_id IS NULL
        )::integer,
        count(*) FILTER (
            WHERE existing_grade.quiz_id IS NOT NULL
                AND (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                    resolved_result.points,
                    CASE
                        WHEN resolved_result.has_description THEN resolved_result.description
                        ELSE existing_grade.description
                    END
                )
        )::integer,
        count(*) FILTER (
            WHERE existing_grade.quiz_id IS NOT NULL
                AND NOT ((existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                    resolved_result.points,
                    CASE
                        WHEN resolved_result.has_description THEN resolved_result.description
                        ELSE existing_grade.description
                    END
                ))
        )::integer,
        count(*) FILTER (
            WHERE NOT resolved_result.has_submission
        )::integer,
        count(*) FILTER (
            WHERE p_mark_attended
                AND resolved_result.participation IS NULL
        )::integer,
        count(*) FILTER (
            WHERE p_mark_attended
                AND resolved_result.participation = 'absent'::data.participation_enum
        )::integer,
        count(*) FILTER (
            WHERE p_mark_attended
                AND resolved_result.participation IS NOT NULL
                AND resolved_result.participation <> 'absent'::data.participation_enum
        )::integer
    INTO inserted_count, updated_count, unchanged_count, submission_created_count,
        attendance_inserted, attendance_updated, attendance_unchanged
    FROM data.resolve_quiz_result_import(p_results) AS resolved_result
    LEFT JOIN api.quiz_grades existing_grade
        ON existing_grade.quiz_id = resolved_result.quiz_id
        AND existing_grade.user_id = resolved_result.user_id;

    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'import_quiz_results accounted for % of % results', inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_mark_attended
        AND attendance_inserted + attendance_updated + attendance_unchanged <> input_count THEN
        RAISE EXCEPTION 'import_quiz_results accounted for % of % attendance rows', attendance_inserted + attendance_updated + attendance_unchanged, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_dry_run THEN
        RETURN NEXT;
        RETURN;
    END IF;

    PERFORM set_config('yeluke.grade_event_source', 'api.import_quiz_results', true);
    PERFORM set_config('yeluke.grade_event_reason', COALESCE(p_reason, ''), true);
    PERFORM set_config('yeluke.grade_event_import_id', import_id, true);

    -- data.quiz_grade has a foreign key onto data.quiz_submission, and quizzes
    -- are paper-only, so nothing a student does ever creates the submission a
    -- grade needs. An import that refused to create them could not record a
    -- paper quiz grade at all, which is why there is no flag to turn this off:
    -- the only setting it could take is the one that never works.
    WITH created_submissions AS (
        INSERT INTO api.quiz_submissions (quiz_id, user_id)
        SELECT resolved_result.quiz_id, resolved_result.user_id
        FROM data.resolve_quiz_result_import(p_results) AS resolved_result
        WHERE NOT resolved_result.has_submission
        RETURNING quiz_id
    )
    SELECT count(*)::integer INTO submission_created_count
    FROM created_submissions;

    WITH resolved_results AS (
        SELECT *
        FROM data.resolve_quiz_result_import(p_results)
    ),
    updated_grades AS (
        UPDATE api.quiz_grades existing_grade
        SET
            points = resolved_result.points,
            description = CASE
                WHEN resolved_result.has_description THEN resolved_result.description
                ELSE existing_grade.description
            END
        FROM resolved_results resolved_result
        WHERE existing_grade.quiz_id = resolved_result.quiz_id
            AND existing_grade.user_id = resolved_result.user_id
            AND (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                resolved_result.points,
                CASE
                    WHEN resolved_result.has_description THEN resolved_result.description
                    ELSE existing_grade.description
                END
            )
        RETURNING existing_grade.quiz_id
    ),
    inserted_grades AS (
        INSERT INTO api.quiz_grades (
            quiz_id,
            user_id,
            points_possible,
            points,
            description
        )
        SELECT
            resolved_result.quiz_id,
            resolved_result.user_id,
            resolved_result.points_possible,
            resolved_result.points,
            resolved_result.description
        FROM resolved_results resolved_result
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.quiz_grades existing_grade
            WHERE existing_grade.quiz_id = resolved_result.quiz_id
                AND existing_grade.user_id = resolved_result.user_id
        )
        RETURNING quiz_id
    )
    SELECT
        (SELECT count(*)::integer FROM updated_grades),
        (SELECT count(*)::integer FROM inserted_grades)
    INTO updated_count, inserted_count;

    PERFORM set_config('yeluke.grade_event_source', '', true);
    PERFORM set_config('yeluke.grade_event_reason', '', true);
    PERFORM set_config('yeluke.grade_event_import_id', '', true);

    -- Attendance last, so the participation values read above are the ones this
    -- import found rather than the ones it just wrote.
    --
    -- data.ensure_student_engagement_rows() has already written an 'absent' row
    -- for every (student, meeting) pair that existed when the student was
    -- enrolled, which is why the loaders this replaces marked nobody attended:
    -- their INSERT ... ON CONFLICT DO NOTHING always hit that row and did
    -- nothing. Promoting 'absent' is the whole point.
    --
    -- 'contributed' and 'led' are faculty judgements that outrank mere
    -- presence, and 'attended' is already the value being written, so the
    -- update touches 'absent' and nothing else. Any participation value added
    -- to data.participation_enum later is left alone until someone decides
    -- where it sits; the test suite pins the enum's labels so that decision
    -- cannot be skipped by accident.
    IF p_mark_attended THEN
        WITH resolved_results AS (
            SELECT *
            FROM data.resolve_quiz_result_import(p_results)
        ),
        promoted_engagements AS (
            UPDATE api.engagements existing_engagement
            SET participation = 'attended'::data.participation_enum
            FROM resolved_results resolved_result
            WHERE existing_engagement.user_id = resolved_result.user_id
                AND existing_engagement.meeting_slug = resolved_result.meeting_slug
                AND existing_engagement.participation = 'absent'::data.participation_enum
            RETURNING existing_engagement.user_id
        ),
        -- A meeting created after a student enrolled has no engagement row for
        -- them: nothing backfills one. Those are inserts, not promotions.
        added_engagements AS (
            INSERT INTO api.engagements (user_id, meeting_slug, participation)
            SELECT
                resolved_result.user_id,
                resolved_result.meeting_slug,
                'attended'::data.participation_enum
            FROM resolved_results resolved_result
            WHERE resolved_result.participation IS NULL
            RETURNING user_id
        )
        SELECT
            (SELECT count(*)::integer FROM added_engagements),
            (SELECT count(*)::integer FROM promoted_engagements)
        INTO attendance_inserted, attendance_updated;
    END IF;

    -- Every payload row has to end up somewhere. The loader this replaces let
    -- rows fall out of an inner join and still reported success.
    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'import_quiz_results wrote % of % results', inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_mark_attended
        AND attendance_inserted + attendance_updated + attendance_unchanged <> input_count THEN
        RAISE EXCEPTION 'import_quiz_results wrote % of % attendance rows', attendance_inserted + attendance_updated + attendance_unchanged, input_count
            USING ERRCODE = 'XX000';
    END IF;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION import_quiz_results(jsonb, boolean, boolean, text, text) FROM PUBLIC;

-- Read the fractional_credit bounds off a grade exception table's own CHECK
-- constraint, so the extension functions cannot drift from the schema they
-- write to.
--
-- If the constraint is ever reshaped past this pattern both bounds read NULL,
-- every comparison against them is NULL rather than true, and the real write
-- becomes the only check again; the test suite pins the shape so that a reshape
-- is noticed rather than silently tolerated.
CREATE OR REPLACE FUNCTION data.grade_exception_credit_bounds(p_table_name text)
RETURNS TABLE (
    credit_minimum numeric,
    credit_maximum numeric
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        (regexp_match(
            pg_get_constraintdef(credit_constraint.oid),
            'fractional_credit >= \(([0-9.]+)\)::numeric'
        ))[1]::numeric,
        (regexp_match(
            pg_get_constraintdef(credit_constraint.oid),
            'fractional_credit <= \(([0-9.]+)\)::numeric'
        ))[1]::numeric
    FROM pg_constraint credit_constraint
    JOIN pg_class exception_table
        ON exception_table.oid = credit_constraint.conrelid
    JOIN pg_namespace exception_schema
        ON exception_schema.oid = exception_table.relnamespace
    WHERE exception_schema.nspname = 'data'
        AND exception_table.relname = p_table_name
        AND credit_constraint.contype = 'c'
        AND pg_get_constraintdef(credit_constraint.oid) LIKE '%fractional_credit%';
$$;

REVOKE ALL ON FUNCTION data.grade_exception_credit_bounds(text) FROM PUBLIC;

-- Write one assignment grade exception, creating it or moving the one already
-- there.
--
-- This exists as its own function only so that the ON CONFLICT clauses can name
-- assignment_slug, user_id, team_nickname and is_team as bare columns. Inside
-- api.grant_assignment_extension those are OUT parameter names, and plpgsql
-- substitutes a variable for any unqualified identifier that matches one --
-- which an index inference clause cannot be written around, because it accepts
-- no table qualification.
--
-- It is SECURITY INVOKER and writes through the api view, so the caller's own
-- RLS applies: the WITH CHECK on data.assignment_grade_exception still requires
-- the writer to be faculty.
CREATE OR REPLACE FUNCTION data.upsert_assignment_grade_exception(
    p_assignment_slug text,
    p_is_team boolean,
    p_user_id integer,
    p_team_nickname text,
    p_closed_at timestamptz,
    p_fractional_credit numeric
)
RETURNS TABLE (
    written_id integer,
    was_inserted boolean
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- The uniqueness rules are partial indexes, so each branch has to state the
    -- predicate its arbiter carries. This is exactly what PostgREST's
    -- on_conflict cannot say, and why extending a deadline is an RPC rather
    -- than a POST to a view faculty already hold CRUD on.
    --
    -- fractional_credit is in both DO UPDATE lists. The scripts this replaces
    -- left it out, so re-granting an extension at reduced credit silently kept
    -- whatever credit the first grant had.
    --
    -- was_inserted comes out of the write itself rather than a read taken
    -- before it. Two faculty granting the same new extension at once would both
    -- pass a prior existence check and both be told they created the row, even
    -- though one of them conflict-updated the other's.
    --
    -- old is NULL on the insert path and the pre-update row on the conflict
    -- path. The older idiom for this is RETURNING (xmax = 0), which does not
    -- work here: xmax is a system column, an auto-updatable view has no system
    -- columns in its rowtype, and these writes go through api views on purpose
    -- so that RLS applies. old.id is an ordinary column reference and resolves
    -- through the view. It needs PostgreSQL 18, which is what this schema
    -- already requires.
    IF p_is_team THEN
        INSERT INTO api.assignment_grade_exceptions (
            assignment_slug, is_team, team_nickname, closed_at, fractional_credit
        )
        VALUES (
            p_assignment_slug, true, p_team_nickname, p_closed_at, p_fractional_credit
        )
        ON CONFLICT (assignment_slug, team_nickname) WHERE is_team
        DO UPDATE SET
            closed_at = EXCLUDED.closed_at,
            fractional_credit = EXCLUDED.fractional_credit
        RETURNING new.id, old.id IS NULL INTO written_id, was_inserted;
    ELSE
        INSERT INTO api.assignment_grade_exceptions (
            assignment_slug, is_team, user_id, closed_at, fractional_credit
        )
        VALUES (
            p_assignment_slug, false, p_user_id, p_closed_at, p_fractional_credit
        )
        ON CONFLICT (assignment_slug, user_id) WHERE NOT is_team
        DO UPDATE SET
            closed_at = EXCLUDED.closed_at,
            fractional_credit = EXCLUDED.fractional_credit
        RETURNING new.id, old.id IS NULL INTO written_id, was_inserted;
    END IF;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION data.upsert_assignment_grade_exception(text, boolean, integer, text, timestamptz, numeric) FROM PUBLIC;

-- Grant one student, or one student's team, a later deadline on an assignment.
--
-- p_closed_at is absolute. The script this replaces accepted '+7 days' and
-- interpolated it into SQL, which put a client-side convenience inside the
-- database; relative arithmetic belongs to whoever knows what "a week" means
-- for this course.
--
-- On a team assignment the student's CURRENT team is the right team, which is
-- the opposite of the rule api.import_assignment_grades follows. A grade is a
-- record of work already done, so it is attached through the insert-time
-- participant snapshot in data.assignment_submission_participant. An extension
-- authorises work not yet done, and
-- data.assignment_field_submission_is_writable_by_current_user() reads it by
-- joining the exception's team_nickname to the submitting student's current
-- team_nickname. An older team snapshotted here would write a row that the
-- check consuming it could never match.
CREATE OR REPLACE FUNCTION grant_assignment_extension(
    p_user_id integer,
    p_assignment_slug text,
    p_closed_at timestamptz,
    p_fractional_credit numeric DEFAULT 1
)
RETURNS TABLE (
    exception_id integer,
    assignment_slug text,
    is_team boolean,
    user_id integer,
    team_nickname text,
    closed_at timestamptz,
    fractional_credit numeric,
    created boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Everything the queries below read is held in a local whose name matches
    -- no column of any table touched here. The OUT parameters are named for the
    -- JSON the client wants back, and plpgsql refuses an unqualified identifier
    -- that could be either a variable or a column.
    target_slug text;
    target_is_team boolean;
    target_team_nickname text;
    credit_floor numeric;
    credit_ceiling numeric;
BEGIN
    p_fractional_credit := COALESCE(p_fractional_credit, 1);
    target_slug := btrim(p_assignment_slug);

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'grant_assignment_extension requires a user id'
            USING ERRCODE = '22023';
    END IF;

    IF COALESCE(target_slug, '') = '' THEN
        RAISE EXCEPTION 'grant_assignment_extension requires an assignment slug'
            USING ERRCODE = '22023';
    END IF;

    -- A NULL deadline would be refused by the NOT NULL column anyway; saying so
    -- here names the argument that was left out.
    IF p_closed_at IS NULL THEN
        RAISE EXCEPTION 'grant_assignment_extension requires a closed_at, an extension with no deadline is not an extension'
            USING ERRCODE = '22023';
    END IF;

    SELECT bounds.credit_minimum, bounds.credit_maximum
    INTO credit_floor, credit_ceiling
    FROM data.grade_exception_credit_bounds('assignment_grade_exception') AS bounds;

    IF p_fractional_credit < credit_floor OR p_fractional_credit > credit_ceiling THEN
        RAISE EXCEPTION 'grant_assignment_extension requires fractional_credit between % and %, received %',
            credit_floor, credit_ceiling, p_fractional_credit
            USING ERRCODE = '22023';
    END IF;

    -- Read through api.assignments rather than data.assignment so the caller's
    -- own row visibility applies: a caller who cannot see an assignment cannot
    -- extend it.
    SELECT assignment.is_team INTO target_is_team
    FROM api.assignments assignment
    WHERE assignment.slug = target_slug;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'grant_assignment_extension does not know assignment slug: %', target_slug
            USING ERRCODE = '23503';
    END IF;

    SELECT student.team_nickname INTO target_team_nickname
    FROM api.users student
    WHERE student.id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'grant_assignment_extension does not know user id: %', p_user_id
            USING ERRCODE = '23503';
    END IF;

    IF target_is_team AND target_team_nickname IS NULL THEN
        RAISE EXCEPTION 'grant_assignment_extension cannot extend team assignment % for user %, who is on no team', target_slug, p_user_id
            USING ERRCODE = '22023';
    END IF;

    -- A team exception names the team and no user, an individual exception the
    -- other way round; the matches_assignment_is_team constraint refuses
    -- anything else.
    IF NOT target_is_team THEN
        target_team_nickname := NULL;
    END IF;

    -- created comes back out of the write, not out of a read taken before it,
    -- so two faculty granting the same new extension at once cannot both be
    -- told they created the row.
    SELECT written.written_id, written.was_inserted
    INTO exception_id, created
    FROM data.upsert_assignment_grade_exception(
        target_slug, target_is_team, p_user_id, target_team_nickname,
        p_closed_at, p_fractional_credit
    ) AS written;

    assignment_slug := target_slug;
    is_team := target_is_team;
    user_id := CASE WHEN target_is_team THEN NULL ELSE p_user_id END;
    team_nickname := target_team_nickname;
    closed_at := p_closed_at;
    fractional_credit := p_fractional_credit;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION grant_assignment_extension(integer, text, timestamptz, numeric) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
-- Faculty read the participant snapshot to find which team submission a student
-- actually worked on. They can already see every submission, so this adds no
-- visibility; it only makes the historical roster reachable without the api
-- role's RLS context.
GRANT SELECT ON data.team_submission_participation TO faculty;

GRANT EXECUTE ON FUNCTION data.resolve_assignment_grade_import(jsonb) TO faculty;
GRANT EXECUTE ON FUNCTION api.import_assignment_grades(jsonb, boolean, boolean, text, text) TO faculty;
GRANT EXECUTE ON FUNCTION data.resolve_quiz_result_import(jsonb) TO faculty;
GRANT EXECUTE ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) TO faculty;
GRANT EXECUTE ON FUNCTION data.grade_exception_credit_bounds(text) TO faculty;
GRANT EXECUTE ON FUNCTION data.upsert_assignment_grade_exception(text, boolean, integer, text, timestamptz, numeric) TO faculty;
GRANT EXECUTE ON FUNCTION api.grant_assignment_extension(integer, text, timestamptz, numeric) TO faculty;

-- ---------------------------------------------------------------------------
-- The online-quiz remnants (#302 and the paper-only cleanup)
-- ---------------------------------------------------------------------------
-- data.quiz_grade_exception had zero readers: no RLS policy, no view, no
-- function body consulted it. Granting a quiz extension recorded a decision and
-- changed nothing a student could do, so the table goes rather than gaining an
-- RPC. api.grant_assignment_extension stays -- assignment exceptions have two
-- real readers.
DROP VIEW IF EXISTS api.quiz_grade_exceptions;
DROP TABLE IF EXISTS data.quiz_grade_exception;

-- api.quizzes selects quiz.*, so it must go before the columns it depends on.
DROP VIEW IF EXISTS api.quizzes;

-- `is_offline` had one possible value once quizzes went paper-only, and
-- `duration` measured a clock that only ran for an online attempt.
ALTER TABLE data.quiz DROP COLUMN IF EXISTS is_offline;
ALTER TABLE data.quiz DROP COLUMN IF EXISTS duration;

SET search_path = api, public;

create or replace view quizzes
with (security_barrier = true) as
    select
        quiz.*,
        (
            quiz.is_draft = false and
            quiz.open_at < current_timestamp and
            current_timestamp < quiz.closed_at
        ) AS is_open
    from data.quiz
    where request.user_role() = 'faculty'
    or quiz.is_draft = false;

-- It is important to set the correct owner so the RLS policy kicks in.
alter view quizzes owner to api;

-- Compatibility versions. The schema shape genuinely changed, so
-- schema_compatibility_version moves to 4; admin_api_version reaches 8.
create or replace view platform_version as
    select
        'yelukerest'::text as platform,
        1::integer as platform_compatibility_version,
        4::integer as schema_compatibility_version,
        8::integer as admin_api_version;

alter view platform_version owner to api;

COMMENT ON VIEW platform_version IS
    'Single-row compatibility metadata for course admin preflight checks';
COMMENT ON COLUMN platform_version.platform IS
    'Platform identifier expected by course admin tooling';
COMMENT ON COLUMN platform_version.platform_compatibility_version IS
    'Integer compatibility version for Yelukerest platform behavior';
COMMENT ON COLUMN platform_version.schema_compatibility_version IS
    'Integer identifying the api schema shape. Check for membership in the set of shapes the client supports, NOT with >=: a shape can lose columns and views, and version 4 did. A client pinned to >= 3 would pass its own preflight against 4 and then fail on its first request.';
COMMENT ON COLUMN platform_version.admin_api_version IS
    'Integer compatibility version for generic admin API operations. Only ever grows -- each bump adds an RPC without removing one -- so >= is the correct check.';

-- Recreating api.quizzes dropped its comments with it; structure.sql asserts
-- every api view and column carries one.

COMMENT ON VIEW quizzes IS
    'Paper quiz metadata and availability windows';
COMMENT ON COLUMN quizzes.id IS 'Unique quiz id';
COMMENT ON COLUMN quizzes.meeting_slug IS 'Meeting associated with the quiz';
COMMENT ON COLUMN quizzes.points_possible IS 'Maximum score for the quiz';
COMMENT ON COLUMN quizzes.is_draft IS 'Whether the quiz is still hidden from students and TAs';
COMMENT ON COLUMN quizzes.open_at IS 'When the quiz becomes available';
COMMENT ON COLUMN quizzes.closed_at IS 'When the quiz closes';
COMMENT ON COLUMN quizzes.created_at IS 'When this quiz row was created';
COMMENT ON COLUMN quizzes.updated_at IS 'When this quiz row was last updated';
COMMENT ON COLUMN quizzes.is_open IS 'Whether the quiz is published and currently open';

-- Dropping api.quizzes took its grants with it (db/src/authorization/yeluke/quiz.sql).
GRANT SELECT ON api.quizzes TO student, ta;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.quizzes TO faculty;
