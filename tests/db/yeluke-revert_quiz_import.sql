SELECT plan(94)
;
-- Reverting a quiz grade import (#391). The migration's verify.sql pins the
-- boundary: owner, definer, search_path, grants, the DELETE policy. Here is
-- the behaviour, with the ledger and the summary read after each step.
SELECT function_privs_are('api', 'revert_quiz_import', ARRAY['uuid', 'text', 'boolean'], 'anonymous', ARRAY[]::text[], 'anonymous should not be able to execute api.revert_quiz_import')
; SELECT function_privs_are('api', 'revert_quiz_import', ARRAY['uuid', 'text', 'boolean'], 'student', ARRAY[]::text[], 'students should not be able to execute api.revert_quiz_import')
; SELECT function_privs_are('api', 'revert_quiz_import', ARRAY['uuid', 'text', 'boolean'], 'ta', ARRAY[]::text[], 'tas should not be able to execute api.revert_quiz_import')
; SELECT function_privs_are('api', 'revert_quiz_import', ARRAY['uuid', 'text', 'boolean'], 'faculty', ARRAY['EXECUTE'], 'faculty should be able to execute api.revert_quiz_import')
; SELECT
    "is"((
        SELECT pg_get_userbyid(proowner)::text
        FROM pg_proc
        WHERE oid = 'api.revert_quiz_import(uuid, text, boolean)'::regprocedure
    ), 'quiz_importer', 'the reversal is owned by the narrow quiz_importer role')
; SELECT
    "is"((
        SELECT prosecdef
        FROM pg_proc
        WHERE oid = 'api.revert_quiz_import(uuid, text, boolean)'::regprocedure
    ), true, 'the reversal is SECURITY DEFINER')
;
-- Both writers lock the rows they touch in key order, so an import and a
-- reversal over the same rows wait for each other rather than deadlock.
SELECT
    "is"((
        SELECT count(*)::int
        FROM pg_proc p
        WHERE
            p.oid IN ('api.import_quiz_results(jsonb, boolean, boolean, text, text)'::regprocedure, 'api.revert_quiz_import(uuid, text, boolean)'::regprocedure)
            AND p.prosrc ~ E'ORDER BY existing_grade\\.quiz_id, existing_grade\\.user_id\\s+FOR UPDATE OF existing_grade'
            AND p.prosrc ~ E'ORDER BY existing_engagement\\.user_id, existing_engagement\\.meeting_slug\\s+FOR UPDATE OF existing_engagement'
    ), 2, 'the import and the reversal should lock grade and engagement rows in the same key order')
;
-- Replies are kept so the ledger can be held to what the caller was told.
CREATE TEMPORARY TABLE import_reply (
    label text,
    inserted_count int,
    updated_count int,
    unchanged_count int,
    submission_created_count int,
    attendance_inserted int,
    attendance_updated int,
    attendance_unchanged int,
    import_id text,
    dry_run boolean
)
; CREATE TEMPORARY TABLE revert_reply (
    label text,
    inserted_count int,
    updated_count int,
    deleted_count int,
    unchanged_count int,
    attendance_restored int,
    attendance_skipped int,
    import_id uuid,
    reverts_import_id uuid
)
; GRANT select, insert ON pg_temp.import_reply, pg_temp.revert_reply TO faculty, ta
;
--
-- Two imports to undo. A records quiz 2 (structuredquerylang) for five
-- people and marks attendance: abc123 is 'absent' there, bde456 'attended',
-- klj39 'contributed', and jlb325 and crt43 have no engagement row. B
-- changes abc123's existing 13 on quiz 1 (intro).
--
SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; INSERT INTO pg_temp.import_reply
SELECT 'revert-a', *
FROM api.import_quiz_results('[{"meeting_slug":"structuredquerylang","netid":"abc123","points":13},
      {"meeting_slug":"structuredquerylang","netid":"bde456","points":6.5},
      {"meeting_slug":"structuredquerylang","netid":"klj39","points":13},
      {"meeting_slug":"structuredquerylang","netid":"jlb325","points":13},
      {"meeting_slug":"structuredquerylang","netid":"crt43","points":0}]'::jsonb, p_mark_attended := true, p_import_id := 'revert-a', p_reason := 'Quiz 2')
; INSERT INTO pg_temp.import_reply
SELECT 'revert-b', *
FROM api.import_quiz_results('[{"meeting_slug":"intro","netid":"abc123","points":7,"description":"regraded q3"}]'::jsonb, p_import_id := 'revert-b', p_reason := 'Regrade')
; SELECT results_eq('
        SELECT label, inserted_count, updated_count, attendance_inserted, attendance_updated
        FROM pg_temp.import_reply ORDER BY label
    ', ' VALUES (''revert-a''::text, 5, 0, 2, 1), (''revert-b'', 0, 1, 0, 0) ', 'the two imports did what this file assumes')
;
--
-- Refusals that write nothing
--
SELECT throws_ok(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-a''), '''') ', '22023', 'revert_quiz_import requires a non-blank p_reason', 'a reversal without a reason should be refused')
; SELECT throws_ok(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-a''), ''   '') ', '22023', NULL, 'a reversal with a whitespace reason should be refused')
; SELECT throws_ok(' SELECT * FROM api.revert_quiz_import(NULL, ''Undo'') ', '22023', NULL, 'a reversal without an import id should be refused')
; SELECT throws_ok(' SELECT * FROM api.revert_quiz_import(''00000000-0000-0000-0000-000000000000'', ''Undo'') ', '23503', 'revert_quiz_import does not know an import with id 00000000-0000-0000-0000-000000000000', 'an unknown import id should be named')
; SELECT throws_like('
        SELECT * FROM api.revert_quiz_import(
            (SELECT import_id::uuid FROM api.import_quiz_results(
                ''[{"meeting_slug":"structuredquerylang","netid":"abc123","points":1}]''::jsonb,
                p_dry_run => true)),
            ''Undo a dry run'')
    ', '%was a dry run and wrote nothing%', 'a dry run header has nothing to revert')
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT throws_ok(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-a''), ''Undo'') ', '42501', NULL, 'a TA should not be able to revert an import')
; SELECT throws_ok(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-a''), ''Undo'', p_force => true) ', '42501', NULL, 'a TA should not be able to force a reversal either')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT throws_ok(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-a''), ''Undo'') ', '42501', NULL, 'a student should not be able to revert an import')
; RESET role
; SELECT results_eq(' SELECT count(*)::int FROM data.quiz_grade_import WHERE reverts_import_id IS NOT NULL ', ' VALUES (0) ', 'a refused reversal should leave no header')
; SELECT results_eq(' SELECT count(*)::int FROM data.quiz_grade WHERE quiz_id = 2 ', ' VALUES (5) ', 'a refused reversal should touch no grade')
;
--
-- Reverting the inserts. jlb325 was marked 'contributed' after the import,
-- a judgement the reversal leaves alone.
--
SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; UPDATE api.engagements
SET participation = 'contributed'
WHERE
    user_id = 4
    AND meeting_slug = 'structuredquerylang'
; INSERT INTO pg_temp.revert_reply
SELECT 'undo-a', *
FROM
    api.revert_quiz_import((
        SELECT import_id::uuid
        FROM pg_temp.import_reply
        WHERE label = 'revert-a'
    ), 'Wrong answer key')
; SELECT results_eq('
        SELECT inserted_count, updated_count, deleted_count, unchanged_count, attendance_restored, attendance_skipped,
            reverts_import_id::text = (SELECT import_id FROM pg_temp.import_reply WHERE label = ''revert-a'') AS reverts_a,
            import_id IS DISTINCT FROM reverts_import_id AS has_own_id
        FROM pg_temp.revert_reply WHERE label = ''undo-a''
    ', ' VALUES (0, 0, 5, 0, 2, 1, true, true) ', 'reverting an import of inserts should delete every grade and put back the attendance it changed, skipping a judgement made since')
; SELECT is_empty(' SELECT quiz_id FROM api.quiz_grades WHERE quiz_id = 2 ', 'the inserted grades should be gone')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.quiz_submissions
        WHERE quiz_id = 2
    ), 5, 'the submissions the import created should stay')
; SELECT results_eq('
        SELECT user_id, participation::text
        FROM api.engagements
        WHERE meeting_slug = ''structuredquerylang'' AND user_id IN (1, 2, 3, 4, 5)
        ORDER BY user_id
    ', ' VALUES (1, ''absent''::text), (2, ''attended''), (3, ''contributed''), (4, ''contributed'') ', 'attendance should be put back to absent where the import promoted it, removed where the import created the row, and left alone where it did not or where a judgement was made since')
; SELECT is_empty(' SELECT user_id FROM api.engagements WHERE meeting_slug = ''structuredquerylang'' AND user_id = 5 ', 'the engagement row the import created should be gone, not marked absent')
; SELECT results_eq('
        SELECT e.event_type, e.operation, e.source, e.reason, e.created_by_user_id,
            e.import_id = (SELECT import_id::text FROM pg_temp.revert_reply WHERE label = ''undo-a'') AS carries_reversal_id
        FROM api.quiz_grade_events e
        WHERE e.quiz_id = 2 AND e.operation = ''delete''
        ORDER BY e.user_id
    ', ' SELECT ''voided''::text AS event_type, ''delete''::text AS operation, ''api.revert_quiz_import''::text AS source, ''Wrong answer key''::text AS reason, 3 AS created_by_user_id, true AS carries_reversal_id FROM generate_series(1, 5) ', 'each deleted grade should leave a voided event naming the faculty actor, the reason, and the reversal''s execution id')
;
-- The ledger and the summary, both directions.
SELECT results_eq('
        SELECT v.label, v.actor_user_id, v.actor_role, v.reason, v.dry_run,
            v.reverts_import_id::text = i.import_id AS reverts_a, v.reverted_by_import_id,
            v.inserted_count, v.updated_count, v.deleted_count, v.unchanged_count, v.submission_created_count,
            v.attendance_inserted, v.attendance_updated, v.attendance_deleted, v.attendance_unchanged
        FROM api.quiz_grade_imports v
        JOIN pg_temp.revert_reply r ON r.import_id = v.id
        JOIN pg_temp.import_reply i ON i.label = ''revert-a''
        WHERE r.label = ''undo-a''
    ', ' VALUES (''revert-a''::text, 3, ''faculty''::text, ''Wrong answer key''::text, false, true, NULL::uuid, 0, 0, 5, 0, 0, 0, 1, 1, 3) ', 'the reversal should be listed under the import''s label with reverts_import_id, its actor, reason and counts')
; SELECT results_eq('
        SELECT v.reverted_by_import_id = r.import_id AS reverted_by_undo_a, v.reverts_import_id
        FROM api.quiz_grade_imports v
        JOIN pg_temp.import_reply i ON i.import_id = v.id::text
        JOIN pg_temp.revert_reply r ON r.label = ''undo-a''
        WHERE i.label = ''revert-a''
    ', ' VALUES (true, NULL::uuid) ', 'the reverted import should show the reversal as reverted_by_import_id')
; SELECT results_eq('
        SELECT v.reverted_by_import_id
        FROM api.quiz_grade_imports v
        JOIN pg_temp.import_reply i ON i.import_id = v.id::text
        WHERE i.label = ''revert-b''
    ', ' VALUES (NULL::uuid) ', 'an import nobody reverted shows no reverted_by_import_id')
; RESET role
; SELECT results_eq('
        SELECT i.user_id, i.mutation, i.points_before, i.points_possible_before, i.description_before,
            i.points_after, i.points_possible_after, i.description_after, i.submission_created,
            i.attendance_before::text, i.attendance_after::text
        FROM data.quiz_grade_import_item i
        JOIN pg_temp.revert_reply r ON r.import_id = i.import_id
        WHERE r.label = ''undo-a''
        ORDER BY i.user_id
    ', ' VALUES
        (1, ''delete''::text, 13::real, 13::smallint, NULL::text, NULL::real, NULL::smallint, NULL::text, false, ''attended''::text, ''absent''::text),
        (2, ''delete'', 6.5, 13, NULL, NULL, NULL, NULL, false, ''attended'', ''attended''),
        (3, ''delete'', 13, 13, NULL, NULL, NULL, NULL, false, ''contributed'', ''contributed''),
        (4, ''delete'', 13, 13, NULL, NULL, NULL, NULL, false, ''contributed'', ''contributed''),
        (5, ''delete'', 0, 13, NULL, NULL, NULL, NULL, false, ''attended'', NULL)
    ', 'a reversal''s items should carry the grade it found as the before image, no after image for a delete, and the attendance found and restored')
; SELECT results_eq('
        SELECT h.deleted_count, h.inserted_count, h.updated_count, h.unchanged_count, h.attendance_inserted, h.attendance_updated, h.attendance_deleted, h.attendance_unchanged
        FROM data.quiz_grade_import h JOIN pg_temp.revert_reply r ON r.import_id = h.id WHERE r.label = ''undo-a''
    ', ' VALUES (5, 0, 0, 0, 0, 1, 1, 3) ', 'the reversal''s header should carry the counts the caller was told')
;
-- Reverting twice: the second is refused by name, until forced.
SET LOCAL role TO faculty
; SELECT throws_ok(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-a''), ''Undo again'') ', 'PT409', NULL, 'an import already reverted should be refused')
; SELECT
    throws_like(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-a''), ''Undo again'') ', ('%was already reverted by ' || (
        SELECT import_id::text
        FROM pg_temp.revert_reply
        WHERE label = 'undo-a'
    )) || '%', '...naming the reversal that stands')
;
--
-- Reverting an update puts the prior points and description back, and
-- faculty see the old value again.
--
INSERT INTO pg_temp.revert_reply
SELECT 'undo-b', *
FROM
    api.revert_quiz_import((
        SELECT import_id::uuid
        FROM pg_temp.import_reply
        WHERE label = 'revert-b'
    ), 'Regrade withdrawn')
; SELECT results_eq('
        SELECT inserted_count, updated_count, deleted_count, unchanged_count, attendance_restored, attendance_skipped
        FROM pg_temp.revert_reply WHERE label = ''undo-b''
    ', ' VALUES (0, 1, 0, 0, 0, 0) ', 'reverting an import of one update should report one grade restored')
; SELECT results_eq('
        SELECT points, points_possible, description
        FROM api.quiz_grades
        WHERE quiz_id = 1 AND user_id = 1
    ', ' VALUES (13::real, 13::smallint, NULL::text) ', 'the updated grade should return to its prior points and description')
; SELECT results_eq('
        SELECT event_type, operation, points, description, source, reason, created_by_user_id,
            import_id = (SELECT import_id::text FROM pg_temp.revert_reply WHERE label = ''undo-b'') AS carries_reversal_id
        FROM api.quiz_grade_events
        WHERE quiz_id = 1 AND user_id = 1
        ORDER BY id DESC
        LIMIT 1
    ', ' VALUES (''corrected''::text, ''update''::text, 13::real, NULL::text, ''api.revert_quiz_import''::text, ''Regrade withdrawn''::text, 3, true) ', 'the restored grade should leave a corrected event carrying the reversal''s execution id and the faculty actor')
; RESET role
; SELECT results_eq('
        SELECT i.mutation, i.points_before, i.description_before, i.points_after, i.description_after, i.attendance_before::text, i.attendance_after::text
        FROM data.quiz_grade_import_item i
        JOIN pg_temp.revert_reply r ON r.import_id = i.import_id
        WHERE r.label = ''undo-b''
    ', ' VALUES (''update''::text, 7::real, ''regraded q3''::text, 13::real, NULL::text, ''absent''::text, ''absent''::text) ', 'a restored grade''s item should carry the images in the reversing direction and the attendance untouched')
;
--
-- Reverting the reversal restores the imported state: the five grades come
-- back, with their submissions still there, and attendance is promoted
-- again where the reversal had put it back.
--
SET LOCAL role TO faculty
; INSERT INTO pg_temp.revert_reply
SELECT 'redo-a', *
FROM
    api.revert_quiz_import((
        SELECT import_id
        FROM pg_temp.revert_reply
        WHERE label = 'undo-a'
    ), 'The key was right after all')
; SELECT results_eq('
        SELECT inserted_count, updated_count, deleted_count, unchanged_count, attendance_restored, attendance_skipped,
            reverts_import_id = (SELECT import_id FROM pg_temp.revert_reply WHERE label = ''undo-a'') AS reverts_undo_a
        FROM pg_temp.revert_reply WHERE label = ''redo-a''
    ', ' VALUES (5, 0, 0, 0, 2, 0, true) ', 'reverting a reversal should re-insert the deleted grades and put attendance back as the import left it')
; RESET role
; SELECT results_eq('
        SELECT h.attendance_inserted, h.attendance_updated, h.attendance_deleted, h.attendance_unchanged
        FROM data.quiz_grade_import h JOIN pg_temp.revert_reply r ON r.import_id = h.id WHERE r.label = ''redo-a''
    ', ' VALUES (1, 1, 0, 3) ', 'the row the reversal deleted should be created again, and the row it demoted promoted again')
; SET LOCAL role TO faculty
; SELECT results_eq('
        SELECT user_id, points, points_possible
        FROM api.quiz_grades
        WHERE quiz_id = 2
        ORDER BY user_id
    ', ' VALUES (1, 13::real, 13::smallint), (2, 6.5, 13), (3, 13, 13), (4, 13, 13), (5, 0, 13) ', 'the imported grades should be back as imported')
; SELECT results_eq('
        SELECT user_id, participation::text
        FROM api.engagements
        WHERE meeting_slug = ''structuredquerylang'' AND user_id IN (1, 2, 3, 4, 5)
        ORDER BY user_id
    ', ' VALUES (1, ''attended''::text), (2, ''attended''), (3, ''contributed''), (4, ''contributed''), (5, ''attended'') ', 'attendance should be as the import left it, the judgement made since kept')
; SELECT results_eq('
        SELECT count(*) FILTER (WHERE event_type = ''recorded'')::int AS recorded, count(*) FILTER (WHERE event_type = ''voided'')::int AS voided
        FROM api.quiz_grade_events
        WHERE quiz_id = 2
    ', ' VALUES (10, 5) ', 'the re-inserted grades should leave recorded events of their own')
; SELECT results_eq('
        SELECT v.reverted_by_import_id = redo.import_id AS undo_a_reverted_by_redo_a
        FROM api.quiz_grade_imports v
        JOIN pg_temp.revert_reply undo ON undo.import_id = v.id
        JOIN pg_temp.revert_reply redo ON redo.label = ''redo-a''
        WHERE undo.label = ''undo-a''
    ', ' VALUES (true) ', 'the reversal should show the reversal that undid it')
;
--
-- A later change blocks a normal reversal, naming the grade, and nothing
-- is written. Import C changes intro/abc123 to 9; faculty then hand-edit it
-- to 8.
--
INSERT INTO pg_temp.import_reply
SELECT 'revert-c', *
FROM api.import_quiz_results('[{"meeting_slug":"intro","netid":"abc123","points":9}]'::jsonb, p_import_id := 'revert-c', p_reason := 'Second look')
; UPDATE api.quiz_grades
SET points = 8
WHERE
    quiz_id = 1
    AND user_id = 1
; SELECT
    throws_ok(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-c''), ''Undo the second look'') ', 'PT409', ('revert_quiz_import: these grades changed after import ' || (
        SELECT import_id
        FROM pg_temp.import_reply
        WHERE label = 'revert-c'
    )) || ' and would be overwritten: intro/abc123; nothing was reverted. Pass p_force to restore the before images regardless', 'a grade changed since the import should block the reversal by name')
; SELECT results_eq(' SELECT points FROM api.quiz_grades WHERE quiz_id = 1 AND user_id = 1 ', ' VALUES (8::real) ', 'a blocked reversal should leave the grade as it is')
; SELECT is_empty(' SELECT id FROM api.quiz_grade_imports WHERE reason = ''Undo the second look'' ', 'a blocked reversal should leave no header')
;
-- A change and a change back leaves the value as the import wrote it, but
-- the events say it moved: still blocked.
INSERT INTO pg_temp.import_reply
SELECT 'revert-d', *
FROM api.import_quiz_results('[{"meeting_slug":"intro","netid":"abc123","points":10}]'::jsonb, p_import_id := 'revert-d', p_reason := 'Third look')
; UPDATE api.quiz_grades
SET points = 11
WHERE
    quiz_id = 1
    AND user_id = 1
; UPDATE api.quiz_grades
SET points = 10
WHERE
    quiz_id = 1
    AND user_id = 1
; SELECT throws_like(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-d''), ''Undo the third look'') ', '%would be overwritten: intro/abc123;%', 'a grade changed and changed back since the import should still block the reversal')
;
-- Forced: the before image comes back over the later work, under the same
-- linked audit. D found 8 and wrote 10; forcing its reversal restores 8.
INSERT INTO pg_temp.revert_reply
SELECT 'force-d', *
FROM
    api.revert_quiz_import((
        SELECT import_id::uuid
        FROM pg_temp.import_reply
        WHERE label = 'revert-d'
    ), 'Third look withdrawn, overriding the hand edits', p_force := true)
; SELECT results_eq('
        SELECT inserted_count, updated_count, deleted_count, unchanged_count,
            reverts_import_id::text = (SELECT import_id FROM pg_temp.import_reply WHERE label = ''revert-d'') AS reverts_d
        FROM pg_temp.revert_reply WHERE label = ''force-d''
    ', ' VALUES (0, 1, 0, 0, true) ', 'a forced reversal should restore the before image and link to the import')
; SELECT results_eq(' SELECT points FROM api.quiz_grades WHERE quiz_id = 1 AND user_id = 1 ', ' VALUES (8::real) ', 'a forced reversal should overwrite the later work with the before image')
; SELECT results_eq('
        SELECT v.reason, v.actor_user_id, v.actor_role, v.updated_count, v.reverts_import_id::text = i.import_id AS reverts_d
        FROM api.quiz_grade_imports v
        JOIN pg_temp.revert_reply r ON r.import_id = v.id
        JOIN pg_temp.import_reply i ON i.label = ''revert-d''
        WHERE r.label = ''force-d''
    ', ' VALUES (''Third look withdrawn, overriding the hand edits''::text, 3, ''faculty''::text, 1, true) ', 'a forced reversal should be listed like any other, with its reason')
; SELECT results_eq('
        SELECT event_type, points, reason, import_id = (SELECT import_id::text FROM pg_temp.revert_reply WHERE label = ''force-d'') AS carries_reversal_id
        FROM api.quiz_grade_events
        WHERE quiz_id = 1 AND user_id = 1
        ORDER BY id DESC
        LIMIT 1
    ', ' VALUES (''corrected''::text, 8::real, ''Third look withdrawn, overriding the hand edits''::text, true) ', 'a forced reversal''s event should carry its execution id')
; RESET role
; SELECT results_eq('
        SELECT i.mutation, i.points_before, i.points_after
        FROM data.quiz_grade_import_item i
        JOIN pg_temp.revert_reply r ON r.import_id = i.import_id
        WHERE r.label = ''force-d''
    ', ' VALUES (''update''::text, 10::real, 8::real) ', 'a forced reversal''s item should record the state it found, not the state the import left')
;
--
-- A forced reversal of an insert whose grade is already gone has nothing
-- to do for it, and says so with an item carrying no image at all.
--
SET LOCAL role TO faculty
; INSERT INTO pg_temp.import_reply
SELECT 'revert-e', *
FROM api.import_quiz_results('[{"meeting_slug":"intro","netid":"jlb325","points":5}]'::jsonb, p_import_id := 'revert-e', p_reason := 'Late sheet')
; DELETE FROM api.quiz_grades
WHERE
    quiz_id = 1
    AND user_id = 4
; SELECT throws_like(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-e''), ''Undo the late sheet'') ', '%would be overwritten: intro/jlb325;%', 'an inserted grade deleted since should block the reversal by name')
; INSERT INTO pg_temp.revert_reply
SELECT 'force-e', *
FROM
    api.revert_quiz_import((
        SELECT import_id::uuid
        FROM pg_temp.import_reply
        WHERE label = 'revert-e'
    ), 'Undo the late sheet regardless', p_force := true)
; SELECT results_eq('
        SELECT inserted_count, updated_count, deleted_count, unchanged_count
        FROM pg_temp.revert_reply WHERE label = ''force-e''
    ', ' VALUES (0, 0, 0, 1) ', 'a forced reversal should count a grade already gone as unchanged')
; RESET role
; SELECT results_eq('
        SELECT i.mutation, i.points_before, i.points_possible_before, i.description_before, i.points_after, i.points_possible_after, i.description_after
        FROM data.quiz_grade_import_item i
        JOIN pg_temp.revert_reply r ON r.import_id = i.import_id
        WHERE r.label = ''force-e''
    ', ' VALUES (''unchanged''::text, NULL::real, NULL::smallint, NULL::text, NULL::real, NULL::smallint, NULL::text) ', 'its item should carry no image before or after')
;
--
-- points_possible is the quiz's, cascaded onto every grade by foreign key.
-- A change to the quiz moves every grade on it, so it blocks a reversal;
-- forced, the reversal restores points and description and the grade keeps
-- the quiz's current points_possible, which the item records. Import F
-- changes bde456's 0 on quiz 1 to 6; the quiz then goes to 14 points.
--
SET LOCAL role TO faculty
; INSERT INTO pg_temp.import_reply
SELECT 'revert-f', *
FROM api.import_quiz_results('[{"meeting_slug":"intro","netid":"bde456","points":6}]'::jsonb, p_import_id := 'revert-f', p_reason := 'Found a page')
; RESET role
; UPDATE data.quiz
SET points_possible = 14
WHERE id = 1
; SET LOCAL role TO faculty
; SELECT throws_like(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-f''), ''Undo the page'') ', '%would be overwritten: intro/bde456;%', 'a quiz whose points_possible changed since should block a reversal of grades on it')
; INSERT INTO pg_temp.revert_reply
SELECT 'force-f', *
FROM
    api.revert_quiz_import((
        SELECT import_id::uuid
        FROM pg_temp.import_reply
        WHERE label = 'revert-f'
    ), 'Undo the page regardless', p_force := true)
; SELECT results_eq('
        SELECT updated_count FROM pg_temp.revert_reply WHERE label = ''force-f''
    ', ' VALUES (1) ', 'a forced reversal should still restore the grade')
; SELECT results_eq('
        SELECT points, points_possible, description
        FROM api.quiz_grades
        WHERE quiz_id = 1 AND user_id = 2
    ', ' VALUES (0::real, 14::smallint, NULL::text) ', 'the grade should return to its prior points and keep the quiz''s current points_possible')
; RESET role
; SELECT results_eq('
        SELECT i.mutation, i.points_before, i.points_possible_before, i.points_after, i.points_possible_after
        FROM data.quiz_grade_import_item i
        JOIN pg_temp.revert_reply r ON r.import_id = i.import_id
        WHERE r.label = ''force-f''
    ', ' VALUES (''update''::text, 6::real, 14::smallint, 0::real, 14::smallint) ', 'its item should record the points_possible the grade kept on both sides')
;
--
-- A grade the import found unchanged is not the import's to undo. Import G
-- sends abc123's quiz 1 grade as it is (8); faculty then change it; the
-- reversal leaves the change alone and records the grade as it found it.
--
SET LOCAL role TO faculty
; INSERT INTO pg_temp.import_reply
SELECT 'revert-g', *
FROM api.import_quiz_results('[{"meeting_slug":"intro","netid":"abc123","points":8}]'::jsonb, p_import_id := 'revert-g', p_reason := 'Same sheet again')
; SELECT results_eq(' SELECT unchanged_count FROM pg_temp.import_reply WHERE label = ''revert-g'' ', ' VALUES (1) ', 'import G found the grade unchanged')
; UPDATE api.quiz_grades
SET points = 9
WHERE
    quiz_id = 1
    AND user_id = 1
; INSERT INTO pg_temp.revert_reply
SELECT 'undo-g', *
FROM
    api.revert_quiz_import((
        SELECT import_id::uuid
        FROM pg_temp.import_reply
        WHERE label = 'revert-g'
    ), 'Undo the same sheet')
; SELECT results_eq('
        SELECT inserted_count, updated_count, deleted_count, unchanged_count FROM pg_temp.revert_reply WHERE label = ''undo-g''
    ', ' VALUES (0, 0, 0, 1) ', 'reverting an import that changed nothing is accepted and changes nothing')
; SELECT results_eq(' SELECT points FROM api.quiz_grades WHERE quiz_id = 1 AND user_id = 1 ', ' VALUES (9::real) ', 'a later change to a grade the import found unchanged should survive the reversal')
; RESET role
; SELECT results_eq('
        SELECT i.mutation, i.points_before, i.points_after
        FROM data.quiz_grade_import_item i
        JOIN pg_temp.revert_reply r ON r.import_id = i.import_id
        WHERE r.label = ''undo-g''
    ', ' VALUES (''unchanged''::text, 9::real, 9::real) ', 'its item should record the grade as the reversal found it')
;
--
-- The summary agrees with the headers, reversals included, and every event
-- a reversal wrote links to a reversal header.
--
SELECT is_empty('
        SELECT h.id
        FROM data.quiz_grade_import h
        LEFT JOIN api.quiz_grade_imports v ON v.id = h.id
        WHERE v.id IS NULL
           OR (v.inserted_count, v.updated_count, v.deleted_count, v.unchanged_count, v.submission_created_count)
              <> (h.inserted_count, h.updated_count, h.deleted_count, h.unchanged_count, h.submission_created_count)
           OR (v.attendance_inserted, v.attendance_updated, v.attendance_deleted, v.attendance_unchanged)
              <> (h.attendance_inserted, h.attendance_updated, h.attendance_deleted, h.attendance_unchanged)
           OR v.reverts_import_id IS DISTINCT FROM h.reverts_import_id
    ', 'every header should be listed with the counts the summary takes from the items agreeing with the header')
; SELECT is_empty('
        SELECT e.id
        FROM data.quiz_grade_event e
        WHERE e.source = ''api.revert_quiz_import''
          AND NOT EXISTS (
            SELECT 1 FROM data.quiz_grade_import h
            WHERE h.id::text = e.import_id AND h.reverts_import_id IS NOT NULL AND NOT h.dry_run
          )
    ', 'every event a reversal wrote should link to a reversal header')
; SELECT results_eq(' SELECT count(*)::int FROM data.quiz_grade_import WHERE reverts_import_id IS NOT NULL ', ' VALUES (7) ', 'seven reversals ran: undo-a, undo-b, redo-a, force-d, force-e, force-f and undo-g')
;
-- With the imported state back, the reversal of A no longer stands, so
-- reverting A is no longer refused as already reverted; it is refused as
-- moved, since the grades were re-inserted after it. The way back is to
-- revert the reversal that restored them.
SET LOCAL role TO faculty
; SELECT throws_like(' SELECT * FROM api.revert_quiz_import((SELECT import_id::uuid FROM pg_temp.import_reply WHERE label = ''revert-a''), ''Undo once more'') ', '%these grades changed after import%structuredquerylang/abc123, structuredquerylang/bde456, structuredquerylang/crt43, structuredquerylang/jlb325, structuredquerylang/klj39;%', 'an import whose reversal was itself reverted is refused as moved, not as already reverted')
; SELECT results_eq('
        SELECT inserted_count, deleted_count, attendance_restored, attendance_skipped
        FROM api.revert_quiz_import((SELECT import_id FROM pg_temp.revert_reply WHERE label = ''redo-a''), ''Undo the redo'')
    ', ' VALUES (0, 5, 2, 0) ', 'reverting the reversal that restored the grades deletes them again')
; SELECT is_empty(' SELECT quiz_id FROM api.quiz_grades WHERE quiz_id = 2 ', 'the re-inserted grades should be gone again')
; RESET role
;
-- The transaction-local grade event settings must not outlive the reversal.
UPDATE data.quiz_grade
SET points = 12
WHERE
    quiz_id = 1
    AND user_id = 1
; SELECT results_eq('
        SELECT source, reason, import_id
        FROM api.quiz_grade_events
        WHERE quiz_id = 1 AND user_id = 1
        ORDER BY id DESC
        LIMIT 1
    ', ' VALUES (''data.quiz_grade''::text, NULL::text, NULL::text) ', 'a later hand edit should not inherit the reversal''s source, reason, or import id')
;
--
-- The item rules that describe a reversal. Superuser here; the header is a
-- real one.
--
SELECT throws_ok(' INSERT INTO data.quiz_grade_import_item SELECT h.id, 99, 9901, ''delete'', 5, 13, NULL, 5, 13, NULL, false, NULL, NULL FROM data.quiz_grade_import h WHERE h.label = ''revert-c'' ', '23514', NULL, 'a delete item cannot carry an after image')
; SELECT throws_ok(' INSERT INTO data.quiz_grade_import_item SELECT h.id, 99, 9901, ''delete'', NULL, NULL, NULL, NULL, NULL, NULL, false, NULL, NULL FROM data.quiz_grade_import h WHERE h.label = ''revert-c'' ', '23514', NULL, 'a delete item must carry a before image')
; SELECT throws_ok(' INSERT INTO data.quiz_grade_import_item SELECT h.id, 99, 9901, ''insert'', NULL, NULL, NULL, NULL, NULL, NULL, false, NULL, NULL FROM data.quiz_grade_import h WHERE h.label = ''revert-c'' ', '23514', NULL, 'an insert item must carry an after image')
; SELECT throws_ok(' INSERT INTO data.quiz_grade_import_item SELECT h.id, 99, 9901, ''update'', 5, 13, NULL, NULL, NULL, NULL, false, NULL, NULL FROM data.quiz_grade_import h WHERE h.label = ''revert-c'' ', '23514', NULL, 'an update item must carry an after image')
; SELECT throws_ok(' INSERT INTO data.quiz_grade_import_item SELECT h.id, 99, 9901, ''unchanged'', NULL, NULL, ''gone'', NULL, NULL, ''gone'', false, NULL, NULL FROM data.quiz_grade_import h WHERE h.label = ''revert-c'' ', '23514', NULL, 'an unchanged item with no grade carries no description either')
; SELECT throws_ok(' INSERT INTO data.quiz_grade_import_item SELECT h.id, 99, 9901, ''unchanged'', 5, 13, NULL, 5, 13, NULL, false, ''absent'', NULL FROM data.quiz_grade_import h WHERE h.label = ''revert-c'' ', '23514', NULL, 'an item cannot record an absence going to no row')
; SELECT lives_ok(' INSERT INTO data.quiz_grade_import_item SELECT h.id, 99, 9902, ''unchanged'', 5, 13, NULL, 5, 13, NULL, false, ''attended'', NULL FROM data.quiz_grade_import h WHERE h.label = ''revert-c'' ', 'an item can record an attended row removed')
; SELECT throws_ok(' INSERT INTO data.quiz_grade_import_item SELECT h.id, 99, 9901, ''unchanged'', 5, 13, NULL, 5, 13, NULL, false, ''contributed'', ''absent'' FROM data.quiz_grade_import h WHERE h.label = ''revert-c'' ', '23514', NULL, 'an item cannot record a judgement demoted')
; SELECT lives_ok(' INSERT INTO data.quiz_grade_import_item SELECT h.id, 99, 9901, ''unchanged'', 5, 13, NULL, 5, 13, NULL, false, ''attended'', ''absent'' FROM data.quiz_grade_import h WHERE h.label = ''revert-c'' ', 'an item can record attended put back to absent')
;
--
-- The DELETE policy is the backstop: a throwaway definer owned by
-- quiz_importer, with none of the reversal's checks, may delete a grade and
-- put attendance back under a faculty claim and not under a TA claim, and
-- may not write or overwrite a judgement under either. Grades at this
-- point: abc123 has 12 on quiz 1 from the hand edit above; bde456 is
-- 'attended' at structuredquerylang and klj39 'contributed'.
--
CREATE FUNCTION pg_temp.write_as_importer(p_statement text) RETURNS void SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
BEGIN
    EXECUTE p_statement;
END;
$$
; ALTER FUNCTION pg_temp.write_as_importer(text) OWNER TO quiz_importer
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''DELETE FROM data.quiz_grade WHERE quiz_id = 1 AND user_id = 1'') ', 'a TA-claimed definer deleting a grade runs without error...')
; RESET role
; SELECT results_eq(' SELECT points FROM data.quiz_grade WHERE quiz_id = 1 AND user_id = 1 ', ' VALUES (12::real) ', '...but the quiz_grade DELETE policy alone lets it delete nothing')
; SET LOCAL role TO ta
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''UPDATE data.engagement SET participation = ''''absent'''' WHERE user_id = 2 AND meeting_slug = ''''structuredquerylang'''''') ', 'a TA-claimed definer demoting attendance runs without error...')
; RESET role
; SELECT results_eq(' SELECT participation::text FROM data.engagement WHERE user_id = 2 AND meeting_slug = ''structuredquerylang'' ', ' VALUES (''attended''::text) ', '...but the engagement UPDATE policy alone lets a TA claim demote nothing')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''DELETE FROM data.quiz_grade WHERE quiz_id = 1 AND user_id = 1'') ', 'the policies leave a faculty claim free to delete a grade through the owner')
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''UPDATE data.engagement SET participation = ''''absent'''' WHERE user_id = 2 AND meeting_slug = ''''structuredquerylang'''''') ', 'the policies leave a faculty claim free to put attendance back through the owner')
; SELECT throws_ok(' SELECT pg_temp.write_as_importer(''UPDATE data.engagement SET participation = ''''led'''' WHERE user_id = 2 AND meeting_slug = ''''structuredquerylang'''''') ', '42501', NULL, 'but not to write a judgement through it')
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''UPDATE data.engagement SET participation = ''''absent'''' WHERE user_id = 3 AND meeting_slug = ''''structuredquerylang'''''') ', 'a faculty-claimed definer demoting a judgement runs without error...')
; RESET role
; SELECT results_eq(' SELECT participation::text FROM data.engagement WHERE user_id = 3 AND meeting_slug = ''structuredquerylang'' ', ' VALUES (''contributed''::text) ', '...but the engagement UPDATE policy alone lets it demote nothing')
; SELECT is_empty(' SELECT quiz_id FROM data.quiz_grade WHERE quiz_id = 1 AND user_id = 1 ', 'the faculty-claimed delete through the owner took effect')
;
-- The engagement DELETE policy: only under a faculty claim, and only a row
-- saying attended. bde456 is 'attended' at intro and now 'absent' at
-- structuredquerylang; klj39 is 'contributed' there.
SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''DELETE FROM data.engagement WHERE user_id = 2 AND meeting_slug = ''''intro'''''') ', 'a TA-claimed definer deleting an engagement runs without error...')
; RESET role
; SELECT results_eq(' SELECT participation::text FROM data.engagement WHERE user_id = 2 AND meeting_slug = ''intro'' ', ' VALUES (''attended''::text) ', '...but the engagement DELETE policy alone lets a TA claim delete nothing')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''DELETE FROM data.engagement WHERE meeting_slug = ''''structuredquerylang'''' AND user_id IN (2, 3)'') ', 'a faculty-claimed definer deleting an absent row and a judgement runs without error...')
; RESET role
; SELECT results_eq(' SELECT user_id, participation::text FROM data.engagement WHERE meeting_slug = ''structuredquerylang'' AND user_id IN (2, 3) ORDER BY user_id ', ' VALUES (2, ''absent''::text), (3, ''contributed'') ', '...but the policy admits only a row saying attended, so neither goes')
; SET LOCAL role TO faculty
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''DELETE FROM data.engagement WHERE user_id = 2 AND meeting_slug = ''''intro'''''') ', 'the policies leave a faculty claim free to delete an attended row through the owner')
; RESET role
; SELECT is_empty(' SELECT user_id FROM data.engagement WHERE user_id = 2 AND meeting_slug = ''intro'' ', 'and that delete took effect')
; SELECT results_eq(' SELECT participation::text FROM data.engagement WHERE user_id = 2 AND meeting_slug = ''structuredquerylang'' ', ' VALUES (''absent''::text) ', 'and so did the faculty-claimed demotion')
; SELECT *
FROM finish()
