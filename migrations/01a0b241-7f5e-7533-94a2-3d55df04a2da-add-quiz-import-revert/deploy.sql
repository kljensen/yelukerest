-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.
-- Let faculty revert a quiz-grade import (issue #391).
--
-- The ledger of 01a0b208 records, for every import, the grade before and
-- after each result and the attendance before and after. That is exactly
-- what undoing one needs. api.revert_quiz_import(p_import_id, p_reason,
-- p_force) takes an execution id, the ledger's key, and puts each before
-- image back: a grade the import inserted is deleted, a grade it changed
-- returns to its prior points and description, and attendance goes back
-- where the import promoted it. The quiz submissions the import created stay;
-- they hold no score and a later grade needs them.
--
-- A reversal is itself an import in the ledger: a header with
-- reverts_import_id set, items with the grade before (the state the reversal
-- found) and after (the state it restored), and the grade events it writes
-- carry its execution id. So the summary lists it, the original shows what
-- undid it, and a reversal can be reverted in turn, which puts the imported
-- state back. Nothing here reads a before image that the ledger did not
-- write down.
--
-- Unless p_force, the reversal refuses whole if any grade the import changed
-- has moved since: its current state differs from the item's after image, or
-- a later grade event exists for it. The refusal names each moved grade and
-- writes nothing, no header included. A grade the import found unchanged is
-- neither checked nor written, whatever happened to it since. With p_force the before images are
-- restored regardless, under the same audit, except points_possible, which
-- follows the quiz by foreign key and is never per grade. Attendance is
-- different:
-- 'contributed' and 'led' are faculty judgements, and a person marked one
-- since the import keeps it, forced or not; the reply counts them as skipped.
--
-- Faculty only. Same owner pattern as the import: SECURITY DEFINER under
-- quiz_importer, which gains what a reversal touches and the import did not:
-- DELETE on data.quiz_grade and on data.engagement, and SELECT on the ledger
-- and on the grade event stream, each under a policy requiring a faculty
-- claim. Its engagement UPDATE policy admits a faculty claim moving a row
-- between absent and attended in either direction, where before it admitted
-- absent to attended only.
--
-- The import and the reversal lock the grade and engagement rows they touch
-- in key order, so two of them over the same rows wait for each other
-- rather than deadlock. The import 01a0b208 shipped locked in payload order;
-- it is redefined below with the same body and ordered locks.
-- ---------------------------------------------------------------------------
-- The ledger learns to describe a reversal
-- ---------------------------------------------------------------------------
-- A reversal of an inserted grade is a delete, which the item mutation set
-- did not have: a 'delete' item has a before image and no after image, so
-- the after image columns become nullable and the image rules are restated
-- per mutation. An 'unchanged' item may now carry no image at all: a forced
-- reversal finding that a grade the import inserted is already gone has
-- nothing to do, and records that. The other two rules, that an unchanged
-- item's images agree and an update's differ, stand as they were.
--
-- Attendance may be restored as well as promoted: 'attended' back to
-- 'absent', or back to no row at all where the import created one (a
-- meeting added after the student enrolled has no backfilled row, and a
-- student can read their own rows, so an 'absent' put there would show an
-- absence that never existed). The rule compares null-safely, so an absence
-- going to none is a violation rather than an unknown that passes. Reverting
-- that reversal promotes, or re-creates, the row again.
ALTER TABLE data.quiz_grade_import
    ADD COLUMN deleted_count int NOT NULL DEFAULT 0 CHECK (deleted_count >= 0),
    ADD COLUMN attendance_deleted int NOT NULL DEFAULT 0 CHECK (attendance_deleted >= 0)
; COMMENT ON COLUMN data.quiz_grade_import.deleted_count IS 'Grades a reversal deleted, undoing inserts. Zero for an import.'
; COMMENT ON COLUMN data.quiz_grade_import.attendance_deleted IS 'Engagement rows a reversal deleted, undoing rows an import created. Zero for an import.'
; ALTER TABLE data.quiz_grade_import_item
    ALTER COLUMN points_after DROP NOT NULL,
    ALTER COLUMN points_possible_after DROP NOT NULL,
    DROP CONSTRAINT quiz_grade_import_item_mutation_check,
    ADD CONSTRAINT quiz_grade_import_item_mutation_check CHECK (mutation IN ('insert', 'update', 'unchanged', 'delete')),
    DROP CONSTRAINT quiz_grade_import_item_before_image_iff_existing,
    ADD CONSTRAINT quiz_grade_import_item_images_match_mutation CHECK (CASE mutation
        WHEN
            'insert' THEN points_before IS NULL
            AND points_possible_before IS NULL
            AND description_before IS NULL
            AND points_after IS NOT NULL
            AND points_possible_after IS NOT NULL
        WHEN
            'update' THEN points_before IS NOT NULL
            AND points_possible_before IS NOT NULL
            AND points_after IS NOT NULL
            AND points_possible_after IS NOT NULL
        WHEN
            'delete' THEN points_before IS NOT NULL
            AND points_possible_before IS NOT NULL
            AND points_after IS NULL
            AND points_possible_after IS NULL
            AND description_after IS NULL
        WHEN
            'unchanged' THEN (points_before IS NOT NULL
            AND points_possible_before IS NOT NULL) OR (points_before IS NULL
            AND points_possible_before IS NULL
            AND description_before IS NULL)
    END),
    DROP CONSTRAINT quiz_grade_import_item_attendance_promoted_or_kept,
    ADD CONSTRAINT quiz_grade_import_item_attendance_promoted_kept_or_restored CHECK (attendance_after IS NOT DISTINCT FROM attendance_before OR (attendance_after IS NOT DISTINCT FROM 'attended'::data.participation_enum
    AND (attendance_before IS NULL OR attendance_before = 'absent'::data.participation_enum)) OR (attendance_before IS NOT DISTINCT FROM 'attended'::data.participation_enum
    AND (attendance_after IS NULL OR attendance_after = 'absent'::data.participation_enum)))
; COMMENT ON TABLE data.quiz_grade_import_item IS 'One row per result in a quiz grade import or reversal: the grade before and after (neither for a grade that was not there and is not restored; no after image for a delete), whether its submission was created, and attendance before and after. A dry run records what would have happened. Append-only.'
;
-- ---------------------------------------------------------------------------
-- Privileges: what a reversal touches that the import did not
-- ---------------------------------------------------------------------------
-- DELETE on quiz grades, for the grades an import inserted. Which rows a
-- reversal may delete, those an item of the import being reverted names, is
-- not something a row policy can say: the policy sees the row and the claim,
-- not the call. So the policy says the one thing it can, that a faculty
-- claim is behind the session, and the function's item-driven DELETE is the
-- rule. A TA claim is refused here whatever the function does.
GRANT delete ON data.quiz_grade TO quiz_importer
; CREATE POLICY quiz_importer_delete ON data.quiz_grade FOR DELETE TO quiz_importer USING (request.user_role() = 'faculty')
;
-- The ledger, to read the import being reverted, and the grade event stream,
-- to see whether a grade moved since. Both are faculty-readable through api
-- already; the owner reads them for a faculty claim alone.
GRANT select ON data.quiz_grade_import, data.quiz_grade_import_item, data.quiz_grade_event TO quiz_importer
; CREATE POLICY quiz_importer_select ON data.quiz_grade_import FOR SELECT TO quiz_importer USING (request.user_role() = 'faculty')
; CREATE POLICY quiz_importer_select ON data.quiz_grade_import_item FOR SELECT TO quiz_importer USING (request.user_role() = 'faculty')
; CREATE POLICY quiz_importer_select ON data.quiz_grade_event FOR SELECT TO quiz_importer USING (request.user_role() = 'faculty')
;
-- Attendance both ways for faculty: absent to attended when importing,
-- attended back to absent when reverting, and nothing else, so a judgement
-- is never overwritten by either. The TA half is as 01a0b1c5 wrote it. And
-- DELETE of a row saying attended, for the rows an import created; as with
-- grades, which rows is the function's item-driven logic.
GRANT delete ON data.engagement TO quiz_importer
; CREATE POLICY quiz_importer_delete ON data.engagement FOR DELETE TO quiz_importer USING (request.user_role() = 'faculty'
AND participation = 'attended'::data.participation_enum)
; DROP POLICY quiz_importer_update ON data.engagement
; CREATE POLICY quiz_importer_update ON data.engagement FOR UPDATE TO quiz_importer USING ((request.user_role() = 'faculty'
AND participation IN ('absent'::data.participation_enum, 'attended'::data.participation_enum)) OR (request.user_role() = 'ta'
AND participation = 'absent'::data.participation_enum)) WITH CHECK ((request.user_role() = 'faculty'
AND participation IN ('absent'::data.participation_enum, 'attended'::data.participation_enum)) OR (request.user_role() = 'ta'
AND participation = 'attended'::data.participation_enum
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
)))
;
-- ---------------------------------------------------------------------------
-- The reversal
-- ---------------------------------------------------------------------------
-- Planned the way the import is: one item per item of the import being
-- reverted, read once under row locks, with the counts, the ledger and the
-- writes all taken from that plan, and a check afterwards that the writes
-- did what the plan said. The plan's before image is the grade as the
-- reversal found it and its after image is the target: the reverted item's
-- before image, or no grade where that image is empty. The mutation follows
-- from the two, so reverting a reversal, whose items have empty before
-- images where grades were deleted, plans inserts.
CREATE FUNCTION api.revert_quiz_import(p_import_id uuid, p_reason text, p_force boolean = false) RETURNS TABLE (inserted_count int, updated_count int, deleted_count int, unchanged_count int, attendance_restored int, attendance_skipped int, import_id uuid, reverts_import_id uuid) SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    execution_id uuid := public.gen_random_uuid();
    reverted data.quiz_grade_import%ROWTYPE;
    item_count integer;
    last_import_event_id bigint;
    offenders text;
    planned_items data.quiz_grade_import_item[];
    planned_counts integer[];
    attendance_inserted integer;
    attendance_updated integer;
    attendance_deleted integer;
    written_attendance integer[];
BEGIN
    -- The role check is the function's own, since SECURITY DEFINER means the
    -- execute grant is the only other gate. The claim is what every row
    -- policy trusts.
    IF request.user_role() IS DISTINCT FROM 'faculty' THEN
        RAISE insufficient_privilege USING MESSAGE = 'revert_quiz_import accepts only faculty credentials';
    END IF;

    p_force := COALESCE(p_force, false);
    import_id := execution_id;
    reverts_import_id := p_import_id;

    IF p_import_id IS NULL THEN
        RAISE EXCEPTION 'revert_quiz_import requires p_import_id, the execution id of the import to undo'
            USING ERRCODE = '22023';
    END IF;

    -- Undoing grades is audited under a reason someone had to write down.
    IF COALESCE(btrim(p_reason), '') = '' THEN
        RAISE EXCEPTION 'revert_quiz_import requires a non-blank p_reason'
            USING ERRCODE = '22023';
    END IF;

    -- Two reversals of one import at once would each find it unreverted. The
    -- header cannot be row-locked, since nothing but the migrator may update
    -- the ledger, so the import id is locked instead, for this transaction.
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_import_id::text, 0));

    SELECT header.* INTO reverted
    FROM data.quiz_grade_import header
    WHERE header.id = p_import_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'revert_quiz_import does not know an import with id %', p_import_id
            USING ERRCODE = '23503';
    END IF;

    IF reverted.dry_run THEN
        RAISE EXCEPTION 'revert_quiz_import: import % was a dry run and wrote nothing, so there is nothing to revert', p_import_id
            USING ERRCODE = '22023';
    END IF;

    -- An import already undone by a reversal that stands is refused by name,
    -- rather than as a list of grades that moved. A reversal that was itself
    -- reverted does not stand: the imported state is back and may be undone
    -- again.
    IF NOT p_force THEN
        SELECT string_agg(reversal.id::text, ', ' ORDER BY reversal.created_at) INTO offenders
        FROM data.quiz_grade_import reversal
        WHERE reversal.reverts_import_id = p_import_id
            AND NOT EXISTS (
                SELECT 1
                FROM data.quiz_grade_import later_reversal
                WHERE later_reversal.reverts_import_id = reversal.id
            );

        IF offenders IS NOT NULL THEN
            RAISE EXCEPTION 'revert_quiz_import: import % was already reverted by %; nothing was reverted. Pass p_force to restore its before images regardless', p_import_id, offenders
                USING ERRCODE = 'PT409';
        END IF;
    END IF;

    SELECT count(*) INTO item_count
    FROM data.quiz_grade_import_item item
    WHERE item.import_id = p_import_id;

    -- The import stamped its execution id on every grade event it wrote. Any
    -- event for one of its grades after the last of those is later work.
    SELECT max(event.id) INTO last_import_event_id
    FROM data.quiz_grade_event event
    WHERE event.import_id = p_import_id::text;

    -- Lock the grade and engagement rows this reversal will read and may
    -- write, before anything below reads them, for the reason the import
    -- does, and in the key order the import takes them in. Rows the owner's
    -- UPDATE policies do not admit are not locked; they are not written
    -- either.
    PERFORM 1
    FROM data.quiz_grade_import_item item
    JOIN data.quiz_grade existing_grade
        ON existing_grade.quiz_id = item.quiz_id
        AND existing_grade.user_id = item.user_id
    WHERE item.import_id = p_import_id
    ORDER BY existing_grade.quiz_id, existing_grade.user_id
    FOR UPDATE OF existing_grade;

    PERFORM 1
    FROM data.quiz_grade_import_item item
    JOIN data.quiz quiz
        ON quiz.id = item.quiz_id
    JOIN data.engagement existing_engagement
        ON existing_engagement.user_id = item.user_id
        AND existing_engagement.meeting_slug = quiz.meeting_slug
    WHERE item.import_id = p_import_id
        AND item.attendance_before IS DISTINCT FROM item.attendance_after
    ORDER BY existing_engagement.user_id, existing_engagement.meeting_slug
    FOR UPDATE OF existing_engagement;

    -- Every grade the import changed must be as the import left it: the same
    -- points, points possible and description, and no grade event since. A
    -- grade the import found unchanged is not checked; the reversal leaves it
    -- alone whatever happened to it. The whole reversal is refused, naming
    -- each moved grade, before anything is written.
    IF NOT p_force THEN
        SELECT string_agg(quiz.meeting_slug || '/' || student.netid, ', '
            ORDER BY quiz.meeting_slug || '/' || student.netid) INTO offenders
        FROM data.quiz_grade_import_item item
        JOIN data.quiz quiz
            ON quiz.id = item.quiz_id
        JOIN data."user" student
            ON student.id = item.user_id
        LEFT JOIN data.quiz_grade existing_grade
            ON existing_grade.quiz_id = item.quiz_id
            AND existing_grade.user_id = item.user_id
        WHERE item.import_id = p_import_id
            AND item.mutation <> 'unchanged'
            AND ((existing_grade.points, existing_grade.points_possible, existing_grade.description) IS DISTINCT FROM (
                    item.points_after, item.points_possible_after, item.description_after
                )
                OR EXISTS (
                    SELECT 1
                    FROM data.quiz_grade_event later_event
                    WHERE later_event.quiz_id = item.quiz_id
                        AND later_event.user_id = item.user_id
                        AND later_event.id > last_import_event_id
                ));

        IF offenders IS NOT NULL THEN
            RAISE EXCEPTION 'revert_quiz_import: these grades changed after import % and would be overwritten: %; nothing was reverted. Pass p_force to restore the before images regardless', p_import_id, offenders
                USING ERRCODE = 'PT409';
        END IF;
    END IF;

    -- The plan. A grade the import found unchanged is not the import's to
    -- undo: it is recorded as it is now, whatever happened to it since, and
    -- not written. A grade's points_possible is the quiz's, by the foreign key
    -- (quiz_id, points_possible) ON UPDATE CASCADE, so a restored grade
    -- keeps the value it has and a re-created one takes the value it had;
    -- restoring an old value would break the key once the quiz moved on.
    -- Attendance goes back only where the import changed it and the row
    -- still says what the import wrote: to 'absent', or to no row where the
    -- import created one; a row since marked anything else is left as it
    -- is.
    SELECT array_agg(ROW(
        execution_id,
        item.quiz_id,
        item.user_id,
        CASE
            WHEN item.mutation = 'unchanged' THEN 'unchanged'
            WHEN existing_grade.quiz_id IS NULL AND item.points_before IS NULL THEN 'unchanged'
            WHEN existing_grade.quiz_id IS NULL THEN 'insert'
            WHEN item.points_before IS NULL THEN 'delete'
            WHEN (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                item.points_before, item.description_before
            ) THEN 'update'
            ELSE 'unchanged'
        END,
        existing_grade.points,
        existing_grade.points_possible,
        existing_grade.description,
        CASE
            WHEN item.mutation = 'unchanged' THEN existing_grade.points
            ELSE item.points_before
        END,
        CASE
            WHEN item.mutation = 'unchanged' THEN existing_grade.points_possible
            WHEN item.points_before IS NULL THEN NULL
            ELSE COALESCE(existing_grade.points_possible, item.points_possible_before)
        END,
        CASE
            WHEN item.mutation = 'unchanged' THEN existing_grade.description
            WHEN item.points_before IS NULL THEN NULL
            ELSE item.description_before
        END,
        false,
        existing_engagement.participation,
        CASE
            WHEN item.attendance_before IS NOT DISTINCT FROM item.attendance_after
                THEN existing_engagement.participation
            WHEN existing_engagement.participation IS NOT DISTINCT FROM item.attendance_after
                THEN item.attendance_before
            ELSE existing_engagement.participation
        END
    )::data.quiz_grade_import_item)
    INTO planned_items
    FROM data.quiz_grade_import_item item
    LEFT JOIN data.quiz_grade existing_grade
        ON existing_grade.quiz_id = item.quiz_id
        AND existing_grade.user_id = item.user_id
    LEFT JOIN data.quiz quiz
        ON quiz.id = item.quiz_id
    LEFT JOIN data.engagement existing_engagement
        ON existing_engagement.user_id = item.user_id
        AND existing_engagement.meeting_slug = quiz.meeting_slug
    WHERE item.import_id = p_import_id;

    SELECT
        count(*) FILTER (
            WHERE planned.mutation = 'insert'
        )::integer,
        count(*) FILTER (
            WHERE planned.mutation = 'update'
        )::integer,
        count(*) FILTER (
            WHERE planned.mutation = 'delete'
        )::integer,
        count(*) FILTER (
            WHERE planned.mutation = 'unchanged'
        )::integer,
        count(*) FILTER (
            WHERE planned.attendance_after IS DISTINCT FROM planned.attendance_before
        )::integer,
        count(*) FILTER (
            WHERE planned.attendance_before IS NULL
                AND planned.attendance_after IS NOT NULL
        )::integer,
        count(*) FILTER (
            WHERE planned.attendance_before IS NOT NULL
                AND planned.attendance_after IS NOT NULL
                AND planned.attendance_after <> planned.attendance_before
        )::integer,
        count(*) FILTER (
            WHERE planned.attendance_before IS NOT NULL
                AND planned.attendance_after IS NULL
        )::integer
    INTO inserted_count, updated_count, deleted_count, unchanged_count, attendance_restored,
        attendance_inserted, attendance_updated, attendance_deleted
    FROM unnest(planned_items) AS planned;

    SELECT count(*)::integer - attendance_restored INTO attendance_skipped
    FROM data.quiz_grade_import_item item
    WHERE item.import_id = p_import_id
        AND item.attendance_before IS DISTINCT FROM item.attendance_after;

    IF inserted_count + updated_count + deleted_count + unchanged_count <> item_count THEN
        RAISE EXCEPTION 'revert_quiz_import accounted for % of % items', inserted_count + updated_count + deleted_count + unchanged_count, item_count
            USING ERRCODE = 'XX000';
    END IF;

    -- The ledger: a header linked to the import it undoes, carrying that
    -- import's label so the two list together, and the plan as its items.
    INSERT INTO data.quiz_grade_import (
        id,
        label,
        actor_user_id,
        actor_role,
        reason,
        dry_run,
        inserted_count,
        updated_count,
        deleted_count,
        unchanged_count,
        submission_created_count,
        attendance_inserted,
        attendance_updated,
        attendance_deleted,
        attendance_unchanged,
        reverts_import_id
    )
    VALUES (
        execution_id,
        reverted.label,
        request.user_id(),
        request.user_role(),
        p_reason,
        false,
        inserted_count,
        updated_count,
        deleted_count,
        unchanged_count,
        0,
        attendance_inserted,
        attendance_updated,
        attendance_deleted,
        item_count - attendance_restored,
        p_import_id
    );

    INSERT INTO data.quiz_grade_import_item
    SELECT planned.*
    FROM unnest(planned_items) AS planned;

    planned_counts := ARRAY[inserted_count, updated_count, deleted_count,
        attendance_inserted, attendance_updated, attendance_deleted];

    PERFORM set_config('yeluke.grade_event_source', 'api.revert_quiz_import', true);
    PERFORM set_config('yeluke.grade_event_reason', p_reason, true);
    PERFORM set_config('yeluke.grade_event_import_id', execution_id::text, true);

    -- The grade writes execute the plan against the rows that still hold its
    -- before images; the locks above make that certain, and the count check
    -- below refuses the reversal if it was not.
    WITH planned AS (
        SELECT *
        FROM unnest(planned_items) AS planned
    ),
    deleted_grades AS (
        DELETE FROM data.quiz_grade existing_grade
        USING planned item
        WHERE item.mutation = 'delete'
            AND existing_grade.quiz_id = item.quiz_id
            AND existing_grade.user_id = item.user_id
            AND (existing_grade.points, existing_grade.points_possible, existing_grade.description) IS NOT DISTINCT FROM (
                item.points_before, item.points_possible_before, item.description_before
            )
        RETURNING existing_grade.quiz_id
    ),
    updated_grades AS (
        UPDATE data.quiz_grade existing_grade
        SET
            points = item.points_after,
            description = item.description_after
        FROM planned item
        WHERE item.mutation = 'update'
            AND existing_grade.quiz_id = item.quiz_id
            AND existing_grade.user_id = item.user_id
            AND (existing_grade.points, existing_grade.description) IS NOT DISTINCT FROM (
                item.points_before, item.description_before
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
            item.quiz_id,
            item.user_id,
            item.points_possible_after,
            item.points_after,
            item.description_after
        FROM planned item
        WHERE item.mutation = 'insert'
        RETURNING quiz_id
    )
    SELECT
        (SELECT count(*)::integer FROM inserted_grades),
        (SELECT count(*)::integer FROM updated_grades),
        (SELECT count(*)::integer FROM deleted_grades)
    INTO inserted_count, updated_count, deleted_count;

    PERFORM set_config('yeluke.grade_event_source', '', true);
    PERFORM set_config('yeluke.grade_event_reason', '', true);
    PERFORM set_config('yeluke.grade_event_import_id', '', true);

    -- Attendance: a row the import promoted goes back to absent, a row it
    -- created goes away, and, reverting a reversal, the other way round.
    WITH planned AS (
        SELECT item.*, quiz.meeting_slug
        FROM unnest(planned_items) AS item
        JOIN data.quiz quiz
            ON quiz.id = item.quiz_id
        WHERE item.attendance_after IS DISTINCT FROM item.attendance_before
    ),
    added_engagements AS (
        INSERT INTO data.engagement (user_id, meeting_slug, participation)
        SELECT item.user_id, item.meeting_slug, item.attendance_after
        FROM planned item
        WHERE item.attendance_before IS NULL
        RETURNING user_id
    ),
    restored_engagements AS (
        UPDATE data.engagement existing_engagement
        SET participation = item.attendance_after
        FROM planned item
        WHERE item.attendance_before IS NOT NULL
            AND item.attendance_after IS NOT NULL
            AND existing_engagement.user_id = item.user_id
            AND existing_engagement.meeting_slug = item.meeting_slug
            AND existing_engagement.participation = item.attendance_before
        RETURNING existing_engagement.user_id
    ),
    removed_engagements AS (
        DELETE FROM data.engagement existing_engagement
        USING planned item
        WHERE item.attendance_after IS NULL
            AND existing_engagement.user_id = item.user_id
            AND existing_engagement.meeting_slug = item.meeting_slug
            AND existing_engagement.participation = item.attendance_before
        RETURNING existing_engagement.user_id
    )
    SELECT ARRAY[
        (SELECT count(*)::integer FROM added_engagements),
        (SELECT count(*)::integer FROM restored_engagements),
        (SELECT count(*)::integer FROM removed_engagements)
    ]
    INTO written_attendance;

    IF planned_counts IS DISTINCT FROM ARRAY[inserted_count, updated_count, deleted_count] || written_attendance THEN
        RAISE EXCEPTION 'revert_quiz_import wrote counts that differ from the ledger it recorded: planned %, wrote %', planned_counts, ARRAY[inserted_count, updated_count, deleted_count] || written_attendance
            USING ERRCODE = 'XX000';
    END IF;

    RETURN NEXT;
END;
$$
;
-- Handing ownership to quiz_importer needs it to hold CREATE on api for the
-- duration of the ALTER and not afterwards, as for the import.
GRANT create ON SCHEMA api TO quiz_importer
; ALTER FUNCTION api.revert_quiz_import(uuid, text, boolean) OWNER TO quiz_importer
; REVOKE create ON SCHEMA api FROM quiz_importer
; REVOKE ALL ON FUNCTION api.revert_quiz_import(uuid, text, boolean) FROM public
; GRANT execute ON FUNCTION api.revert_quiz_import(uuid, text, boolean) TO faculty
; COMMENT ON FUNCTION api.revert_quiz_import(uuid, text, boolean) IS 'Undo a quiz grade import by its execution id, restoring every before image its ledger recorded: an inserted grade is deleted, a changed grade returns to its prior points and description, and attendance the import promoted goes back to absent, or to no row where the import created one, unless someone since marked contributed or led. Created submissions stay. Refused whole, naming the grades, if any grade the import changed has moved since, unless p_force. Faculty only; p_reason is required. Runs as its own audited import with reverts_import_id set, and can itself be reverted.'
;
-- ---------------------------------------------------------------------------
-- The import, locking in key order
-- ---------------------------------------------------------------------------
-- The body 01a0b208 shipped, with one change: the grade and engagement rows
-- it locks up front are taken in key order, (quiz_id, user_id) and
-- (user_id, meeting_slug), the order the reversal above takes them in. Two
-- writers that lock the same rows in different orders can each wait on the
-- other; in one order the second waits for the first. CREATE OR REPLACE
-- keeps the owner, quiz_importer, and the execute grants.
CREATE OR REPLACE FUNCTION api.import_quiz_results(p_results jsonb, p_mark_attended boolean = false, p_dry_run boolean = false, p_import_id text = NULL, p_reason text = NULL) RETURNS TABLE (inserted_count int, updated_count int, unchanged_count int, submission_created_count int, attendance_inserted int, attendance_updated int, attendance_unchanged int, import_id text, dry_run boolean) SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    caller_is_ta boolean;
    execution_id uuid := public.gen_random_uuid();
    input_count integer;
    description_limit integer;
    offenders text;
    planned_items data.quiz_grade_import_item[];
    planned_counts integer[];
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
    -- The execution id is the import's identity: returned, stamped on every
    -- grade event, and the key of the ledger. The caller's p_import_id is a
    -- label on the header and nothing more.
    import_id := execution_id::text;

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

    -- Lock the grade and engagement rows this import will read and may
    -- write, before anything below reads them. Under READ COMMITTED a
    -- concurrent write to the same grade would otherwise be waited for by
    -- the UPDATE alone, after the plan had recorded the row as it was. Held
    -- here, the lock makes the other writer wait for this import, or this
    -- import plan from what the other writer committed. Rows the owner's
    -- UPDATE policies do not admit are not locked; they are not written
    -- either. Taken in key order, the order api.revert_quiz_import takes
    -- them in, so an import and a reversal that touch the same rows wait
    -- for each other rather than deadlock.
    PERFORM 1
    FROM data.resolve_quiz_result_import(p_results) AS resolved_result
    JOIN data.quiz_grade existing_grade
        ON existing_grade.quiz_id = resolved_result.quiz_id
        AND existing_grade.user_id = resolved_result.user_id
    ORDER BY existing_grade.quiz_id, existing_grade.user_id
    FOR UPDATE OF existing_grade;

    IF p_mark_attended THEN
        PERFORM 1
        FROM data.resolve_quiz_result_import(p_results) AS resolved_result
        JOIN data.engagement existing_engagement
            ON existing_engagement.user_id = resolved_result.user_id
            AND existing_engagement.meeting_slug = resolved_result.meeting_slug
        ORDER BY existing_engagement.user_id, existing_engagement.meeting_slug
        FOR UPDATE OF existing_engagement;
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

    -- The plan: one ledger item per result, read once. The counts, the
    -- ledger, and the grade writes all come from this array, so the grade a
    -- real run writes is the after image the ledger records, whatever the
    -- quiz or grade rows say by then. (The quiz row cannot be locked here:
    -- the owner holds SELECT on data.quiz and nothing more.) An update
    -- leaves points_possible as it was; an insert takes the quiz's.
    SELECT array_agg(ROW(
        execution_id,
        resolved_result.quiz_id,
        resolved_result.user_id,
        CASE
            WHEN existing_grade.quiz_id IS NULL THEN 'insert'
            WHEN (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                resolved_result.points,
                CASE
                    WHEN resolved_result.has_description THEN resolved_result.description
                    ELSE existing_grade.description
                END
            ) THEN 'update'
            ELSE 'unchanged'
        END,
        existing_grade.points,
        existing_grade.points_possible,
        existing_grade.description,
        resolved_result.points,
        COALESCE(existing_grade.points_possible, resolved_result.points_possible),
        CASE
            WHEN resolved_result.has_description THEN resolved_result.description
            ELSE existing_grade.description
        END,
        NOT resolved_result.has_submission,
        resolved_result.participation,
        CASE
            WHEN p_mark_attended
                AND (resolved_result.participation IS NULL
                    OR resolved_result.participation = 'absent'::data.participation_enum)
                THEN 'attended'::data.participation_enum
            ELSE resolved_result.participation
        END
    )::data.quiz_grade_import_item)
    INTO planned_items
    FROM data.resolve_quiz_result_import(p_results) AS resolved_result
    LEFT JOIN data.quiz_grade existing_grade
        ON existing_grade.quiz_id = resolved_result.quiz_id
        AND existing_grade.user_id = resolved_result.user_id;

    SELECT
        count(*) FILTER (
            WHERE item.mutation = 'insert'
        )::integer,
        count(*) FILTER (
            WHERE item.mutation = 'update'
        )::integer,
        count(*) FILTER (
            WHERE item.mutation = 'unchanged'
        )::integer,
        count(*) FILTER (
            WHERE item.submission_created
        )::integer,
        count(*) FILTER (
            WHERE p_mark_attended
                AND item.attendance_before IS NULL
        )::integer,
        count(*) FILTER (
            WHERE p_mark_attended
                AND item.attendance_before = 'absent'::data.participation_enum
        )::integer,
        count(*) FILTER (
            WHERE p_mark_attended
                AND item.attendance_before IS NOT NULL
                AND item.attendance_before <> 'absent'::data.participation_enum
        )::integer
    INTO inserted_count, updated_count, unchanged_count, submission_created_count,
        attendance_inserted, attendance_updated, attendance_unchanged
    FROM unnest(planned_items) AS item;

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

    -- The ledger. Written once the batch has passed every check, so a refused
    -- batch leaves no header, and before the dry-run return, so a dry run
    -- leaves one saying what it would have done. The items are the plan
    -- itself, so their before images are the state this import found. A real
    -- run checks below that it wrote what it recorded here.
    INSERT INTO data.quiz_grade_import (
        id,
        label,
        actor_user_id,
        actor_role,
        reason,
        dry_run,
        inserted_count,
        updated_count,
        unchanged_count,
        submission_created_count,
        attendance_inserted,
        attendance_updated,
        attendance_unchanged
    )
    VALUES (
        execution_id,
        nullif(btrim(p_import_id), ''),
        request.user_id(),
        request.user_role(),
        nullif(p_reason, ''),
        p_dry_run,
        inserted_count,
        updated_count,
        unchanged_count,
        submission_created_count,
        attendance_inserted,
        attendance_updated,
        attendance_unchanged
    );

    INSERT INTO data.quiz_grade_import_item
    SELECT item.*
    FROM unnest(planned_items) AS item;

    IF p_dry_run THEN
        RETURN NEXT;
        RETURN;
    END IF;

    planned_counts := ARRAY[inserted_count, updated_count, submission_created_count,
        attendance_inserted, attendance_updated];

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
        SELECT item.quiz_id, item.user_id
        FROM unnest(planned_items) AS item
        WHERE item.submission_created
        RETURNING quiz_id
    )
    SELECT count(*)::integer INTO submission_created_count
    FROM created_submissions;

    -- The grade writes execute the plan: an update writes the after image
    -- onto the row that still holds the before image, and an insert writes
    -- the after image whole. The row locks above make the before-image match
    -- certain; it is written down anyway, so a row that moved regardless is
    -- skipped and the count check below refuses the import.
    WITH planned AS (
        SELECT *
        FROM unnest(planned_items) AS item
    ),
    updated_grades AS (
        UPDATE data.quiz_grade existing_grade
        SET
            points = item.points_after,
            description = item.description_after
        FROM planned item
        WHERE item.mutation = 'update'
            AND existing_grade.quiz_id = item.quiz_id
            AND existing_grade.user_id = item.user_id
            AND (existing_grade.points, existing_grade.description) IS NOT DISTINCT FROM (
                item.points_before, item.description_before
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
            item.quiz_id,
            item.user_id,
            item.points_possible_after,
            item.points_after,
            item.description_after
        FROM planned item
        WHERE item.mutation = 'insert'
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

    -- The ledger was written from the state this import found; the writes
    -- ran afterwards, each against its own snapshot. If anything moved in
    -- between, the ledger would describe an import that did not happen, so
    -- the whole transaction goes instead.
    IF planned_counts IS DISTINCT FROM ARRAY[inserted_count, updated_count, submission_created_count,
        attendance_inserted, attendance_updated] THEN
        RAISE EXCEPTION 'import_quiz_results wrote counts that differ from the ledger it recorded: planned %, wrote %', planned_counts, ARRAY[inserted_count, updated_count, submission_created_count, attendance_inserted, attendance_updated]
            USING ERRCODE = 'XX000';
    END IF;

    RETURN NEXT;
END;
$$
; COMMENT ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) IS 'Import paper quiz results keyed on meeting_slug and netid, with final absolute points, optional attendance marking, dry run, and a ledger. Every call, dry or real, writes one data.quiz_grade_import header and one item per result with the grade before and after; import_id in the reply is the generated execution id that the header and the grade events carry, and p_import_id is kept on the header as a label. Faculty and TAs. A TA must give p_reason, can grade students only, sees no draft quiz, and records grades once: a batch that would change any existing grade is refused whole, naming the rows.'
;
-- ---------------------------------------------------------------------------
-- The faculty summary, both directions
-- ---------------------------------------------------------------------------
-- As 01a0b208 defined it, plus deleted_count from the items and, for a
-- header that a reversal undid, that reversal's id; the most recent one, if
-- an import was reverted, restored, and reverted again. Recreated rather than
-- replaced, so the columns sit where they read.
DROP VIEW api.quiz_grade_imports
; CREATE VIEW api.quiz_grade_imports WITH (security_barrier=true) AS
    SELECT
        header.id, header.label, header.actor_user_id, header.actor_role,
        header.reason, header.dry_run, header.created_at,
        header.reverts_import_id, reversal.id AS reverted_by_import_id,
        COALESCE(item.inserted_count, 0) AS inserted_count,
        COALESCE(item.updated_count, 0) AS updated_count,
        COALESCE(item.deleted_count, 0) AS deleted_count,
        COALESCE(item.unchanged_count, 0) AS unchanged_count,
        COALESCE(item.submission_created_count, 0) AS submission_created_count,
        header.attendance_inserted, header.attendance_updated,
        header.attendance_deleted, header.attendance_unchanged
    FROM
        data.quiz_grade_import header
        LEFT JOIN (
            SELECT
                i.import_id,
                count(*) FILTER (WHERE i.mutation = 'insert')::int AS inserted_count,
                count(*) FILTER (WHERE i.mutation = 'update')::int AS updated_count,
                count(*) FILTER (WHERE i.mutation = 'delete')::int AS deleted_count,
                count(*) FILTER (WHERE i.mutation = 'unchanged')::int AS unchanged_count,
                count(*) FILTER (WHERE i.submission_created)::int AS submission_created_count
            FROM data.quiz_grade_import_item i
            GROUP BY i.import_id
        ) item ON item.import_id = header.id
        LEFT JOIN LATERAL (
            SELECT r.id
            FROM data.quiz_grade_import r
            WHERE r.reverts_import_id = header.id
            ORDER BY r.created_at DESC, r.id DESC
            LIMIT 1
        ) reversal ON true
    WHERE request.user_role() = 'faculty'::text
    ORDER BY header.created_at DESC
; ALTER VIEW api.quiz_grade_imports
    OWNER TO api
; COMMENT ON VIEW api.quiz_grade_imports IS 'Every call of api.import_quiz_results and api.revert_quiz_import, dry runs included, newest first, with what it did. Faculty only.'
; COMMENT ON COLUMN api.quiz_grade_imports.id IS 'Generated execution id; the import_id the call returned and the one its quiz grade events carry'
; COMMENT ON COLUMN api.quiz_grade_imports.label IS 'The caller''s p_import_id, if any; a reversal carries the label of the import it undid. A label, not an identity: two calls may share one'
; COMMENT ON COLUMN api.quiz_grade_imports.actor_user_id IS 'User who ran the import'
; COMMENT ON COLUMN api.quiz_grade_imports.actor_role IS 'Role the import ran under: faculty or ta'
; COMMENT ON COLUMN api.quiz_grade_imports.reason IS 'The p_reason given, if any'
; COMMENT ON COLUMN api.quiz_grade_imports.dry_run IS 'True when nothing was written and the counts say what would have been'
; COMMENT ON COLUMN api.quiz_grade_imports.created_at IS 'When the import ran'
; COMMENT ON COLUMN api.quiz_grade_imports.reverts_import_id IS 'The import this one reversed, if it is a reversal'
; COMMENT ON COLUMN api.quiz_grade_imports.reverted_by_import_id IS 'The most recent reversal of this import, if any'
; COMMENT ON COLUMN api.quiz_grade_imports.inserted_count IS 'Results that recorded a new grade, counted from the items'
; COMMENT ON COLUMN api.quiz_grade_imports.updated_count IS 'Results that changed an existing grade, counted from the items'
; COMMENT ON COLUMN api.quiz_grade_imports.deleted_count IS 'Grades a reversal deleted, counted from the items'
; COMMENT ON COLUMN api.quiz_grade_imports.unchanged_count IS 'Results that matched the existing grade, counted from the items'
; COMMENT ON COLUMN api.quiz_grade_imports.submission_created_count IS 'Quiz submissions the import created for grades to hang on, counted from the items'
; COMMENT ON COLUMN api.quiz_grade_imports.attendance_inserted IS 'Engagement rows created saying attended, by an import or by a reversal of a reversal'
; COMMENT ON COLUMN api.quiz_grade_imports.attendance_updated IS 'Engagement rows promoted from absent to attended, or by a reversal put back to absent'
; COMMENT ON COLUMN api.quiz_grade_imports.attendance_deleted IS 'Engagement rows a reversal deleted, undoing rows an import created'
; COMMENT ON COLUMN api.quiz_grade_imports.attendance_unchanged IS 'People in the batch whose attendance was already recorded, when attendance was asked for; for a reversal, those whose attendance it left alone'
; GRANT select ON api.quiz_grade_imports TO faculty
;
-- ---------------------------------------------------------------------------
-- Compatibility
-- ---------------------------------------------------------------------------
-- admin_api_version 13: api.revert_quiz_import exists, the ledger has a
-- 'delete' mutation, a deleted_count and an attendance_deleted, and
-- api.quiz_grade_imports carries reverted_by_import_id, deleted_count and
-- attendance_deleted. Nothing a client already reads
-- changed shape, so schema_compatibility_version stays 7.
CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::int AS platform_compatibility_version,
        7::int AS schema_compatibility_version, 13::int AS admin_api_version
; ALTER VIEW api.platform_version
    OWNER TO api
; NOTIFY pgrst, 'reload schema'
