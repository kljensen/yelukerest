-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- Puts the import back as 01a01073-roadmap-9-admin-api left it: SECURITY
-- INVOKER, owned by the migrator, faculty-only, reading and writing through
-- the api views. TAs lose the import again. The quiz_importer role stays, for
-- the reason grant_reader's does: roles are cluster-wide, and dropping one
-- here would pull it out from under every other database in the cluster.
-- With the grants below revoked it can do nothing.
--
-- CREATE OR REPLACE keeps the owner and the ACL, so both are put back by
-- name.
CREATE OR REPLACE FUNCTION api.import_quiz_results(p_results jsonb, p_mark_attended boolean = false, p_dry_run boolean = false, p_import_id text = NULL, p_reason text = NULL) RETURNS TABLE (inserted_count int, updated_count int, unchanged_count int, submission_created_count int, attendance_inserted int, attendance_updated int, attendance_unchanged int, import_id text, dry_run boolean) LANGUAGE plpgsql AS $$
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
$$
; ALTER FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) FROM public, ta, quiz_importer
; GRANT execute ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) TO faculty
; COMMENT ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) IS NULL
;
-- The resolver over the api views again, executable by faculty as before.
CREATE OR REPLACE FUNCTION data.resolve_quiz_result_import(p_results jsonb) RETURNS TABLE (meeting_slug text, netid text, quiz_id int, user_id int, points_possible smallint, points real, has_description boolean, description text, has_submission boolean, participation data.participation_enum) LANGUAGE sql STABLE AS $$
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
$$
; REVOKE ALL ON FUNCTION data.resolve_quiz_result_import(jsonb) FROM public, quiz_importer
; GRANT execute ON FUNCTION data.resolve_quiz_result_import(jsonb) TO faculty
; DROP POLICY IF EXISTS quiz_importer_select ON data."user"
; DROP POLICY IF EXISTS quiz_importer_select ON data.quiz_submission
; DROP POLICY IF EXISTS quiz_importer_insert ON data.quiz_submission
; DROP POLICY IF EXISTS quiz_importer_select ON data.quiz_grade
; DROP POLICY IF EXISTS quiz_importer_insert ON data.quiz_grade
; DROP POLICY IF EXISTS quiz_importer_update ON data.quiz_grade
; DROP POLICY IF EXISTS quiz_importer_select ON data.engagement
; DROP POLICY IF EXISTS quiz_importer_insert ON data.engagement
; DROP POLICY IF EXISTS quiz_importer_update ON data.engagement
; REVOKE ALL ON data.quiz, data."user", data.quiz_submission, data.quiz_grade, data.engagement FROM quiz_importer
; REVOKE ALL ON SCHEMA api, data FROM quiz_importer
; DO $$
BEGIN
    IF has_function_privilege('ta', 'api.import_quiz_results(jsonb, boolean, boolean, text, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'ta still holds EXECUTE on api.import_quiz_results';
    END IF;
END;
$$
;
-- Back to the compatibility versions 01a02533-add-user-api-token reported.
CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::int AS platform_compatibility_version,
        7::int AS schema_compatibility_version, 10::int AS admin_api_version
; ALTER VIEW api.platform_version
    OWNER TO api
; NOTIFY pgrst, 'reload schema'
