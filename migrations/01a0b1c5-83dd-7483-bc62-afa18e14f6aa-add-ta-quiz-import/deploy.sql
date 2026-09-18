-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.
-- TAs record paper-quiz grades through one audited import (issue #389).
--
-- Paper quizzes are graded by a TA, who then had no way to put the grades on
-- the platform: every quiz-grade write is faculty-only, by grant on
-- api.quiz_grades, by the row policy's WITH CHECK on data.quiz_grade, and by
-- the execute grant on api.import_quiz_results. The import is the right path
-- (absolute points, idempotent per batch, dry run, every row audited under
-- one import id), but it ran with the caller's role, so granting it to a TA
-- would still have failed at the row policy.
--
-- This gives TAs exactly one capability: running the import. It is the
-- ADR 0005 grant_reader pattern applied to a write. api.import_quiz_results
-- becomes SECURITY DEFINER, owned by quiz_importer: a NOLOGIN NOINHERIT role
-- that owns no table, has no BYPASSRLS, is a member of none of api, ta and
-- faculty, and holds only the table privileges the import needs, admitted by
-- its own row policies on the tables it writes. The function checks the
-- caller's role itself. The row policies are not widened for TAs, and no
-- session flag stands in for authorization.
--
-- Inside the function, for a TA caller:
--   * a non-blank p_reason is required;
--   * a quiz that is still a draft reads as no quiz at all, as it does in
--     api.quizzes;
--   * only students can be graded: not the TA, another TA, or faculty;
--   * the batch records grades once: if any row would change an existing
--     grade, higher or lower, the whole batch is refused, naming the rows.
--     Corrections stay with faculty until an explicit TA regrade exists.
-- The quiz_importer row policies say the students-only, no-draft and
-- record-once rules a second time, so a regression in these checks, or a
-- later function owned by the same role, cannot write past them.
-- Faculty behaviour is unchanged. p_mark_attended is allowed for TAs, who can
-- already write engagements, within the per-request engagement row bound of
-- issue #346, which the import checks up front rather than trips half way.
--
-- The audit trigger keeps reading request.user_id() for the actor, which is
-- the JWT claim and not the definer role, so every event names the TA.
-- ---------------------------------------------------------------------------
-- The owner role
-- ---------------------------------------------------------------------------
-- quiz_importer is provisioned by bin/provision-db.sh, not here: roles are
-- cluster-wide while migrations are per-database, and yelukerest_migrator is
-- deliberately NOCREATEROLE. Same split, and same checks, as
-- 01a0aa42-add-grant-consumer-role. The grants below are only as narrow as
-- the role they land on, so its attributes and its membership boundary are
-- asserted before any GRANT, and a wrong provision fails the transaction.
DO $$
DECLARE
    offending text;
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'quiz_importer') THEN
        RAISE EXCEPTION 'role quiz_importer does not exist'
            USING HINT = 'run bin/provision-db.sh once per cluster before deploying this migration';
    END IF;

    SELECT string_agg(rolname, ', ') INTO offending
    FROM pg_roles
    WHERE rolname = 'quiz_importer'
      AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication OR rolinherit);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'role % must be NOLOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION', offending
            USING HINT = 'bin/provision-db.sh sets those attributes; re-run it';
    END IF;

    -- The role may hold no other role: everything it can do comes from its
    -- own grants below, and `GRANT faculty TO quiz_importer` would otherwise
    -- turn the import into a faculty session.
    SELECT string_agg(held.rolname, ', ') INTO offending
    FROM pg_auth_members m
    JOIN pg_roles held ON held.oid = m.roleid
    WHERE m.member = 'quiz_importer'::regrole;
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'quiz_importer must be a member of no role; found %', offending;
    END IF;

    -- Membership, direct or through another role. quiz_importer may be held
    -- by the migrator, which needs it to hand over ownership, and nobody
    -- else: in particular not the authenticator, or PostgREST could be
    -- switched into it.
    WITH RECURSIVE members AS (
        SELECT m.member FROM pg_auth_members m WHERE m.roleid = 'quiz_importer'::regrole
        UNION
        SELECT m.member FROM pg_auth_members m JOIN members ON m.roleid = members.member
    )
    SELECT string_agg(r.rolname, ', ') INTO offending
    FROM members JOIN pg_roles r ON r.oid = members.member
    WHERE r.rolname <> 'yelukerest_migrator';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'quiz_importer must be held by yelukerest_migrator and nobody else; found %', offending;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_auth_members WHERE roleid = 'quiz_importer'::regrole) THEN
        RAISE EXCEPTION 'yelukerest_migrator does not hold quiz_importer'
            USING HINT = 'bin/provision-db.sh grants it; re-run it';
    END IF;
END;
$$
;
-- ---------------------------------------------------------------------------
-- Privileges: exactly what the import touches
-- ---------------------------------------------------------------------------
-- The import reads quizzes and users to resolve its keys, reads and creates
-- quiz submissions, reads, inserts and updates quiz grades, and reads,
-- inserts and updates engagements. Nothing is deleted, and none of these
-- tables has a sequence. data.quiz_grade_event is written by the audit
-- trigger, which is SECURITY DEFINER under the migrator, so the owner needs
-- nothing there. USAGE on data only: the body references no api object, and
-- request is open to every role.
GRANT usage ON SCHEMA data TO quiz_importer
; GRANT select ON data.quiz, data."user" TO quiz_importer
; GRANT select, insert ON data.quiz_submission TO quiz_importer
; GRANT select, insert, update ON data.quiz_grade TO quiz_importer
; GRANT select, insert, update ON data.engagement TO quiz_importer
;
-- Row policies for the owner, as narrow as the writes it performs. Every one
-- requires a faculty or TA claim, so the privileges above are inert under
-- any other session. Reads admit every row: the import has to see an
-- existing grade, submission or engagement for anyone in the batch to know
-- what it would change, and has to see a faculty row to refuse it by name.
CREATE POLICY quiz_importer_select ON data."user" FOR SELECT TO quiz_importer USING (request.user_role() IN ('faculty', 'ta'))
; CREATE POLICY quiz_importer_select ON data.quiz_submission FOR SELECT TO quiz_importer USING (request.user_role() IN ('faculty', 'ta'))
; CREATE POLICY quiz_importer_select ON data.quiz_grade FOR SELECT TO quiz_importer USING (request.user_role() IN ('faculty', 'ta'))
; CREATE POLICY quiz_importer_select ON data.engagement FOR SELECT TO quiz_importer USING (request.user_role() IN ('faculty', 'ta'))
;
-- Writes carry the TA contract themselves, so that a regression in the
-- function's checks, or a later function owned by quiz_importer, cannot
-- widen it: under a TA claim the target user must be a student and the quiz
-- must not be a draft. Faculty are unrestricted, as through the api views.
-- The function's own checks stay; they give the messages. data.quiz has no
-- row-level security, so the draft rule is a lookup here rather than a
-- policy there.
CREATE POLICY quiz_importer_insert ON data.quiz_submission FOR INSERT TO quiz_importer WITH CHECK (request.user_role() = 'faculty' OR (request.user_role() = 'ta'
AND EXISTS (
    SELECT 1
    FROM data."user" u
    WHERE
        u.id = quiz_submission.user_id
        AND u.role = 'student'
)
AND EXISTS (
    SELECT 1
    FROM data.quiz q
    WHERE
        q.id = quiz_submission.quiz_id
        AND NOT q.is_draft
)))
; CREATE POLICY quiz_importer_insert ON data.quiz_grade FOR INSERT TO quiz_importer WITH CHECK (request.user_role() = 'faculty' OR (request.user_role() = 'ta'
AND EXISTS (
    SELECT 1
    FROM data."user" u
    WHERE
        u.id = quiz_grade.user_id
        AND u.role = 'student'
)
AND EXISTS (
    SELECT 1
    FROM data.quiz q
    WHERE
        q.id = quiz_grade.quiz_id
        AND NOT q.is_draft
)))
;
-- A TA records a grade once; changing one is a faculty act. This is the
-- record-once rule at the row level, beneath the function's own check.
CREATE POLICY quiz_importer_update ON data.quiz_grade FOR UPDATE TO quiz_importer USING (request.user_role() = 'faculty') WITH CHECK (request.user_role() = 'faculty')
;
-- Attendance is the only engagement the import writes: a new row saying
-- attended, or an absent row promoted to attended, for the meeting whose
-- quiz was imported.
CREATE POLICY quiz_importer_insert ON data.engagement FOR INSERT TO quiz_importer WITH CHECK (participation = 'attended'::data.participation_enum
AND (request.user_role() = 'faculty' OR (request.user_role() = 'ta'
AND EXISTS (
    SELECT 1
    FROM data."user" u
    WHERE
        u.id = engagement.user_id
        AND u.role = 'student'
)
AND EXISTS (
    SELECT 1
    FROM data.quiz q
    WHERE
        q.meeting_slug = engagement.meeting_slug
        AND NOT q.is_draft
))))
; CREATE POLICY quiz_importer_update ON data.engagement FOR UPDATE TO quiz_importer USING (request.user_role() IN ('faculty', 'ta')
AND participation = 'absent'::data.participation_enum) WITH CHECK (participation = 'attended'::data.participation_enum
AND (request.user_role() = 'faculty' OR (request.user_role() = 'ta'
AND EXISTS (
    SELECT 1
    FROM data."user" u
    WHERE
        u.id = engagement.user_id
        AND u.role = 'student'
)
AND EXISTS (
    SELECT 1
    FROM data.quiz q
    WHERE
        q.meeting_slug = engagement.meeting_slug
        AND NOT q.is_draft
))))
;
-- ---------------------------------------------------------------------------
-- The resolver, reading the tables rather than the api views
-- ---------------------------------------------------------------------------
-- As 01a01073-roadmap-9-admin-api defined it, but over data.* instead of the
-- api views. A view runs with its owner's policies, and those answer for the
-- caller's claim: under a TA claim api.quiz_submissions shows only the TA's
-- own rows, so has_submission would read false for every student and the
-- import would try to create submissions that exist. The owner's own
-- policies above admit what the import needs. Runs as the caller, which
-- inside the definer is quiz_importer.
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
    JOIN data.quiz quiz
        ON quiz.meeting_slug = btrim(element.value->>'meeting_slug')
    JOIN data."user" student
        ON student.netid = lower(btrim(element.value->>'netid'))
    -- data.quiz_grade has a foreign key onto data.quiz_submission, so this is
    -- what says whether the grade has anything to hang on yet.
    LEFT JOIN data.quiz_submission existing_submission
        ON existing_submission.quiz_id = quiz.id
        AND existing_submission.user_id = student.id
    -- NULL here means no engagement row at all, which is a different case from
    -- a row that says 'absent'.
    LEFT JOIN data.engagement existing_engagement
        ON existing_engagement.meeting_slug = quiz.meeting_slug
        AND existing_engagement.user_id = student.id;
$$
; REVOKE ALL ON FUNCTION data.resolve_quiz_result_import(jsonb) FROM public, faculty
; GRANT execute ON FUNCTION data.resolve_quiz_result_import(jsonb) TO quiz_importer
;
-- ---------------------------------------------------------------------------
-- The import
-- ---------------------------------------------------------------------------
-- The body 01a01073-roadmap-9-admin-api shipped, with these changes: the
-- role check, the TA reason, draft and record-once refusals, data.* in place
-- of the api views, and every reference schema-qualified under a pinned
-- search_path. Same signature, same validation order, same counts.
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
;
-- Handing ownership to quiz_importer needs it to hold CREATE on api for the
-- duration of the ALTER and not afterwards, as for grant_reader: ownership
-- does not depend on it, and a role that can create objects in api is not
-- narrow.
GRANT create ON SCHEMA api TO quiz_importer
; ALTER FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) OWNER TO quiz_importer
; REVOKE create ON SCHEMA api FROM quiz_importer
; REVOKE ALL ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) FROM public
; GRANT execute ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) TO faculty, ta
; COMMENT ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) IS 'Import paper quiz results keyed on meeting_slug and netid, with final absolute points, optional attendance marking, dry run, and an audited import id. Faculty and TAs. A TA must give p_reason, can grade students only, sees no draft quiz, and records grades once: a batch that would change any existing grade is refused whole, naming the rows.'
;
-- ---------------------------------------------------------------------------
-- Compatibility
-- ---------------------------------------------------------------------------
-- admin_api_version 11: the import accepts a TA credential, with the rules
-- above. The shape is unchanged, so schema_compatibility_version stays 7.
CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::int AS platform_compatibility_version,
        7::int AS schema_compatibility_version, 11::int AS admin_api_version
; ALTER VIEW api.platform_version
    OWNER TO api
; NOTIFY pgrst, 'reload schema'
