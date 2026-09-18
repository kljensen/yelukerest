-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- Puts the import back as 01a0b1c5-add-ta-quiz-import left it, writing no
-- ledger and returning the caller's p_import_id as import_id, then drops the
-- ledger. Reverting destroys the record of what each import did; this exists
-- so the migration is reversible, not as a routine operation. CREATE OR
-- REPLACE keeps the owner, quiz_importer, and the execute grants.
CREATE OR REPLACE FUNCTION api.import_quiz_results(p_results jsonb, p_mark_attended boolean = false, p_dry_run boolean = false, p_import_id text = NULL, p_reason text = NULL) RETURNS TABLE (inserted_count int, updated_count int, unchanged_count int, submission_created_count int, attendance_inserted int, attendance_updated int, attendance_unchanged int, import_id text, dry_run boolean) SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    caller_is_ta boolean;
    input_count integer;
    description_limit integer;
    offenders text;
BEGIN
    -- The role check is the function's own, since SECURITY DEFINER means the
    -- execute grant is the only other gate. The claim is what every row
    -- policy trusts.
    IF request.user_role() IS NULL OR request.user_role() NOT IN ('faculty', 'ta') THEN
        RAISE insufficient_privilege USING MESSAGE = 'import_quiz_results accepts only faculty and TA credentials';
    END IF;
    caller_is_ta := request.user_role() = 'ta';

    p_mark_attended := COALESCE(p_mark_attended, false);
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;
    import_id := COALESCE(nullif(btrim(p_import_id), ''), public.gen_random_uuid()::text);

    -- A TA's import is audited under a reason they had to write down.
    IF caller_is_ta AND COALESCE(btrim(p_reason), '') = '' THEN
        RAISE EXCEPTION 'import_quiz_results requires a non-blank p_reason from a TA'
            USING ERRCODE = '22023';
    END IF;

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
    -- not exist. Both are named the same way. To a TA a draft quiz is a quiz
    -- that does not exist, as in api.quizzes, and it is named the same way
    -- too, so the reply says nothing about drafts. data.quiz has no
    -- row-level security, so the rule lives here.
    SELECT string_agg(DISTINCT input_result.meeting_slug, ', '
        ORDER BY input_result.meeting_slug) INTO offenders
    FROM (
        SELECT btrim(element.value->>'meeting_slug') AS meeting_slug
        FROM jsonb_array_elements(p_results) AS element(value)
    ) AS input_result
    WHERE NOT EXISTS (
        SELECT 1
        FROM data.quiz quiz
        WHERE quiz.meeting_slug = input_result.meeting_slug
            AND (NOT caller_is_ta OR NOT quiz.is_draft)
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
        FROM data."user" student
        WHERE student.netid = input_result.netid
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results does not know netid: %', offenders
            USING ERRCODE = '23503';
    END IF;

    -- A TA records grades for students. Faculty may grade any user row, as
    -- before; a TA may not grade themself, another TA, or a faculty member.
    IF caller_is_ta THEN
        SELECT string_agg(DISTINCT student.netid, ', '
            ORDER BY student.netid) INTO offenders
        FROM data."user" student
        WHERE student.role::text <> 'student'
            AND student.netid IN (
                SELECT lower(btrim(element.value->>'netid'))
                FROM jsonb_array_elements(p_results) AS element(value)
            );

        IF offenders IS NOT NULL THEN
            RAISE insufficient_privilege USING MESSAGE = format(
                'import_quiz_results: a TA can only record grades for students, not for: %s', offenders);
        END IF;
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
    FROM pg_catalog.pg_constraint grade_constraint
    JOIN pg_catalog.pg_class grade_table
        ON grade_table.oid = grade_constraint.conrelid
    JOIN pg_catalog.pg_namespace grade_schema
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
    LEFT JOIN data.quiz_grade existing_grade
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

    -- A TA import records grades once. A row that would change an existing
    -- grade -- points or description, up or down -- refuses the whole batch,
    -- before the dry run returns so a dry run says so too. An identical
    -- re-run is unchanged, not a change, and still passes.
    IF caller_is_ta AND updated_count > 0 THEN
        SELECT string_agg(resolved_result.meeting_slug || '/' || resolved_result.netid, ', '
            ORDER BY resolved_result.meeting_slug || '/' || resolved_result.netid) INTO offenders
        FROM data.resolve_quiz_result_import(p_results) AS resolved_result
        JOIN data.quiz_grade existing_grade
            ON existing_grade.quiz_id = resolved_result.quiz_id
            AND existing_grade.user_id = resolved_result.user_id
        WHERE (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
            resolved_result.points,
            CASE
                WHEN resolved_result.has_description THEN resolved_result.description
                ELSE existing_grade.description
            END
        );

        RAISE insufficient_privilege USING MESSAGE = format(
            'import_quiz_results: a TA import records grades once and this batch would change an existing grade for: %s; nothing was imported, ask faculty to make the correction', offenders);
    END IF;

    -- data.engagement carries the per-request row bound of issue #346 for
    -- student and TA claims, and a SECURITY DEFINER wrapper is deliberately
    -- not a way around it: the trigger tallies across the request whatever
    -- role runs the statement. So a TA batch that would mark more attendance
    -- than one request may is refused here, before anything is written,
    -- rather than rolled back after the grades went in. The grade tables
    -- carry no bound, so a batch without attendance is unaffected.
    IF caller_is_ta
        AND p_mark_attended
        AND attendance_inserted + attendance_updated > data.request_row_bound_default() THEN
        RAISE EXCEPTION 'import_quiz_results: a TA request may mark attendance for at most % people and this batch would mark %; send it in batches of that size with the same p_import_id, or without p_mark_attended', data.request_row_bound_default(), attendance_inserted + attendance_updated
            USING ERRCODE = 'PT400';
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
        INSERT INTO data.quiz_submission (quiz_id, user_id)
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
        UPDATE data.quiz_grade existing_grade
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
        INSERT INTO data.quiz_grade (
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
            FROM data.quiz_grade existing_grade
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
            UPDATE data.engagement existing_engagement
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
            INSERT INTO data.engagement (user_id, meeting_slug, participation)
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
; COMMENT ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) IS 'Import paper quiz results keyed on meeting_slug and netid, with final absolute points, optional attendance marking, dry run, and an audited import id. Faculty and TAs. A TA must give p_reason, can grade students only, sees no draft quiz, and records grades once: a batch that would change any existing grade is refused whole, naming the rows.'
; DROP VIEW IF EXISTS api.quiz_grade_imports
; DROP POLICY IF EXISTS quiz_importer_insert ON data.quiz_grade_import
; DROP POLICY IF EXISTS quiz_importer_insert ON data.quiz_grade_import_item
; DROP POLICY IF EXISTS quiz_grade_import_access_policy ON data.quiz_grade_import
; DROP POLICY IF EXISTS quiz_grade_import_item_access_policy ON data.quiz_grade_import_item
; REVOKE ALL ON data.quiz_grade_import, data.quiz_grade_import_item FROM quiz_importer, api
; DROP TABLE IF EXISTS data.quiz_grade_import_item
; DROP TABLE IF EXISTS data.quiz_grade_import
;
-- Back to the compatibility versions 01a0b1c5-add-ta-quiz-import reported.
CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::int AS platform_compatibility_version,
        7::int AS schema_compatibility_version, 11::int AS admin_api_version
; ALTER VIEW api.platform_version
    OWNER TO api
; NOTIFY pgrst, 'reload schema'
