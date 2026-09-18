SELECT plan(121)
; SELECT function_privs_are('api', 'import_quiz_results', ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'], 'anonymous', ARRAY[]::text[], 'anonymous should not be able to execute api.import_quiz_results')
; SELECT function_privs_are('api', 'import_quiz_results', ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'], 'student', ARRAY[]::text[], 'students should not be able to execute api.import_quiz_results')
; SELECT function_privs_are('api', 'import_quiz_results', ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'], 'ta', ARRAY['EXECUTE'], 'tas should be able to execute api.import_quiz_results (#389)')
; SELECT function_privs_are('api', 'import_quiz_results', ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'], 'faculty', ARRAY['EXECUTE'], 'faculty should be able to execute api.import_quiz_results')
; SELECT function_privs_are('data', 'resolve_quiz_result_import', ARRAY['jsonb'], 'student', ARRAY[]::text[], 'students should not be able to resolve quiz import rows')
; SELECT function_privs_are('data', 'resolve_quiz_result_import', ARRAY['jsonb'], 'ta', ARRAY[]::text[], 'tas should not be able to resolve quiz import rows outside the import')
; SELECT function_privs_are('data', 'resolve_quiz_result_import', ARRAY['jsonb'], 'faculty', ARRAY[]::text[], 'faculty should not be able to resolve quiz import rows outside the import')
;
-- The import runs as quiz_importer (#389, the ADR 0005 owner-role pattern
-- applied to a write). The migration's verify.sql pins the whole boundary;
-- these are the parts of it a later change is most likely to loosen.
SELECT
    "is"((
        SELECT pg_get_userbyid(proowner)::text
        FROM pg_proc
        WHERE oid = 'api.import_quiz_results(jsonb, boolean, boolean, text, text)'::regprocedure
    ), 'quiz_importer', 'the import is owned by the narrow quiz_importer role')
; SELECT
    "is"((
        SELECT prosecdef
        FROM pg_proc
        WHERE oid = 'api.import_quiz_results(jsonb, boolean, boolean, text, text)'::regprocedure
    ), true, 'the import is SECURITY DEFINER')
; SELECT results_eq(' SELECT rolcanlogin, rolinherit, rolbypassrls, rolsuper
        FROM pg_roles WHERE rolname = ''quiz_importer'' ', ' VALUES (false, false, false, false) ', 'quiz_importer cannot log in, inherits nothing, and cannot bypass row-level security')
; SELECT is_empty(' SELECT held.rolname FROM pg_auth_members m
        JOIN pg_roles held ON held.oid = m.roleid
        WHERE m.member = ''quiz_importer''::regrole ', 'quiz_importer is a member of no role, api, ta and faculty included')
; SELECT set_eq('
        WITH RECURSIVE members AS (
            SELECT m.member FROM pg_auth_members m WHERE m.roleid = ''quiz_importer''::regrole
            UNION
            SELECT m.member FROM pg_auth_members m JOIN members ON m.roleid = members.member
        )
        SELECT r.rolname::text FROM members JOIN pg_roles r ON r.oid = members.member
    ', ARRAY['yelukerest_migrator'], 'quiz_importer is held by the migrator and nobody else, directly or transitively')
; SELECT set_eq('
        SELECT n.nspname || ''.'' || c.relname || '' '' || priv
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN unnest(ARRAY[''SELECT'', ''INSERT'', ''UPDATE'', ''DELETE'', ''TRUNCATE'', ''REFERENCES'', ''TRIGGER'', ''MAINTAIN'']) priv
        WHERE n.nspname IN (''api'', ''data'')
          AND c.relkind IN (''r'', ''v'', ''m'', ''p'', ''f'')
          AND has_table_privilege(''quiz_importer'', c.oid, priv)
    ', ARRAY['data.quiz SELECT', 'data.user SELECT', 'data.quiz_submission SELECT', 'data.quiz_submission INSERT', 'data.quiz_grade SELECT', 'data.quiz_grade INSERT', 'data.quiz_grade UPDATE', 'data.engagement SELECT', 'data.engagement INSERT', 'data.engagement UPDATE'], 'quiz_importer holds exactly the table privileges the import needs and no other')
; SELECT is_empty('
        SELECT c.oid::regclass::text || '' '' || priv
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN unnest(ARRAY[''USAGE'', ''SELECT'', ''UPDATE'']) priv
        WHERE n.nspname IN (''api'', ''data'')
          AND c.relkind = ''S''
          AND has_sequence_privilege(''quiz_importer'', c.oid, priv)
    ', 'quiz_importer holds no sequence privilege in api or data')
; SELECT set_eq('
        SELECT tablename || '' '' || cmd
        FROM pg_policies
        WHERE ''quiz_importer'' = ANY (roles)
    ', ARRAY['user SELECT', 'quiz_submission SELECT', 'quiz_submission INSERT', 'quiz_grade SELECT', 'quiz_grade INSERT', 'quiz_grade UPDATE', 'engagement SELECT', 'engagement INSERT', 'engagement UPDATE'], 'quiz_importer is admitted by one policy per command it needs, and by no policy for api')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT throws_like(' SELECT * FROM api.import_quiz_results(''[]''::jsonb) ', '%permission denied%', 'students should not be able to import quiz results')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
;
--
-- Payload shape guards
--
SELECT throws_like(' SELECT * FROM api.import_quiz_results(''[]''::jsonb) ', '%refuses to import an empty result list%', 'import_quiz_results should reject an empty result list')
; SELECT throws_like(' SELECT * FROM api.import_quiz_results(''{"netid":"abc123"}''::jsonb) ', '%expects a JSON array%', 'import_quiz_results should reject non-array JSON')
; SELECT throws_like(' SELECT * FROM api.import_quiz_results(''"just-a-string"''::jsonb) ', '%expects a JSON array%', 'import_quiz_results should reject scalar JSON input')
; SELECT throws_like(' SELECT * FROM api.import_quiz_results(''["abc123"]''::jsonb) ', '%expects a JSON object for every result%', 'import_quiz_results should reject array elements that are not objects')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        ''meeting_slug'', ''intro'',
                        ''netid'', ''cardinality'' || i,
                        ''points'', 1
                    )
                )
                FROM generate_series(1, 2001) AS i
            )
        )
    ', '%accepts at most 2000 results%', 'import_quiz_results should reject more than 2000 results')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            jsonb_build_array(
                jsonb_build_object(
                    ''meeting_slug'', ''intro'',
                    ''netid'', ''abc123'',
                    ''points'', 1,
                    ''description'', repeat(''x'', 4194305)
                )
            )
        )
    ', '%payload exceeds the 4 MB limit%', 'import_quiz_results should reject payloads larger than 4 MB')
;
--
-- Row-level validation. Every one of these fails the whole import instead of
-- skipping the offending row, which is the behaviour that differs from the
-- CSV loaders this replaces.
--
SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":1},
              {"meeting_slug":"intro","netid":"","points":1}]''::jsonb
        )
    ', '%requires meeting_slug and netid on every result, missing at position: 2%', 'import_quiz_results should name the position of a row missing its key')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123"}]''::jsonb
        )
    ', '%a missing or null score is not a zero: intro/abc123%', 'import_quiz_results should reject an absent score rather than read it as zero')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":null}]''::jsonb
        )
    ', '%a missing or null score is not a zero: intro/abc123%', 'import_quiz_results should reject a null score rather than read it as zero')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":"12"}]''::jsonb
        )
    ', '%requires numeric points: intro/abc123%', 'import_quiz_results should reject a non-numeric score')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":14}]''::jsonb
        )
    ', '%points between 0 and the quiz points_possible, out of range for: intro/abc123%', 'import_quiz_results should reject a score above points_possible')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":-1}]''::jsonb
        )
    ', '%points between 0 and the quiz points_possible, out of range for: intro/abc123%', 'import_quiz_results should reject a negative score')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":1},
              {"meeting_slug":"intro","netid":"ABC123","points":2}]''::jsonb
        )
    ', '%duplicate meeting_slug/netid key: intro/abc123%', 'import_quiz_results should reject duplicate natural keys rather than take the last write')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"no-such-meeting","netid":"abc123","points":1}]''::jsonb
        )
    ', '%does not know a quiz for meeting slug: no-such-meeting%', 'import_quiz_results should name an unknown meeting slug')
;
-- server-side-apps is a real meeting with no quiz. Unimportable for the same
-- reason as a meeting that does not exist, and named the same way.
SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"server-side-apps","netid":"abc123","points":1}]''::jsonb
        )
    ', '%does not know a quiz for meeting slug: server-side-apps%', 'import_quiz_results should reject a meeting that holds no quiz')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":1},
              {"meeting_slug":"intro","netid":"nosuch999","points":1}]''::jsonb
        )
    ', '%does not know netid: nosuch999%', 'import_quiz_results should name an unknown netid instead of dropping the row')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.quiz_grades
        WHERE quiz_id = 2
    ), 0, 'a rejected import should leave no quiz grades behind')
;
--
-- A dry run exists so that the real import is known to be safe, so anything
-- that would fail the write has to fail the dry run identically.
--
-- The shape api.import_quiz_results parses to learn the description bound. If
-- this constraint is ever reshaped, the import silently stops pre-checking
-- description length and this test is the alarm.
SELECT
    "is"((
        SELECT count(*)::int
        FROM
            pg_constraint grade_constraint
            JOIN pg_class grade_table ON grade_table.oid = grade_constraint.conrelid
            JOIN pg_namespace grade_schema ON grade_schema.oid = grade_table.relnamespace
        WHERE
            grade_schema.nspname = 'data'
            AND grade_table.relname = 'quiz_grade'
            AND grade_constraint.contype = 'c'
            AND pg_get_constraintdef(grade_constraint.oid) ~ E'octet_length\\(description\\) <= \\d+'
    ), 1, 'data.quiz_grade should bound description length in the shape the import reads')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            jsonb_build_array(
                jsonb_build_object(
                    ''meeting_slug'', ''structuredquerylang'',
                    ''netid'', ''abc123'',
                    ''points'', 10,
                    ''description'', repeat(''x'', 8193)
                )
            ),
            p_dry_run => true
        )
    ', '%description of at most 8192 bytes, too long for: structuredquerylang/abc123%', 'a dry run should reject an oversized description rather than let the real write fail')
; SELECT results_eq('
        SELECT inserted_count
        FROM api.import_quiz_results(
            jsonb_build_array(
                jsonb_build_object(
                    ''meeting_slug'', ''structuredquerylang'',
                    ''netid'', ''abc123'',
                    ''points'', 10,
                    ''description'', repeat(''x'', 8192)
                )
            ),
            p_dry_run => true
        )
    ', ' VALUES (1) ', 'a description exactly at the limit should still be accepted')
;
--
-- The participation ladder the attendance promotion walks. If a value is ever
-- added to data.participation_enum, someone has to decide where it sits
-- relative to 'attended', and this test is what makes them.
--
SELECT results_eq(' SELECT unnest(enum_range(NULL::data.participation_enum))::text ', ' VALUES (''absent''::text), (''attended''::text), (''contributed''::text), (''led''::text) ', 'data.participation_enum should hold only the values the attendance promotion has decided about')
;
--
-- Attendance is opt-in. abc123 is 'absent' at every meeting in the sample
-- data, so an import that does not ask for attendance must leave that alone.
--
SELECT results_eq('
        SELECT attendance_inserted, attendance_updated, attendance_unchanged
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":13}]''::jsonb
        )
    ', ' VALUES (0, 0, 0) ', 'an import that does not ask for attendance should report no attendance work')
; SELECT
    "is"((
        SELECT participation::text
        FROM api.engagements
        WHERE
            user_id = 1
            AND meeting_slug = 'intro'
    ), 'absent', 'an import that does not ask for attendance should leave engagement alone')
;
--
-- Dry run
--
SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged, dry_run
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"structuredquerylang","netid":"abc123","points":13},
              {"meeting_slug":"structuredquerylang","netid":"bde456","points":6.5},
              {"meeting_slug":"structuredquerylang","netid":"klj39","points":13},
              {"meeting_slug":"structuredquerylang","netid":"jlb325","points":13},
              {"meeting_slug":"structuredquerylang","netid":"crt43","points":0}]''::jsonb,
            p_mark_attended => true,
            p_dry_run => true
        )
    ', ' VALUES (5, 0, 0, 5, 2, 1, 2, true) ', 'a dry run should report planned grades, submissions, and attendance work')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.quiz_submissions
        WHERE quiz_id = 2
    ), 0, 'a dry run should not create quiz submissions')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.quiz_grades
        WHERE quiz_id = 2
    ), 0, 'a dry run should not write quiz grades')
; SELECT
    "is"((
        SELECT participation::text
        FROM api.engagements
        WHERE
            user_id = 1
            AND meeting_slug = 'structuredquerylang'
    ), 'absent', 'a dry run should not promote attendance')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.engagements
        WHERE user_id = 4
    ), 0, 'a dry run should not create engagement rows')
;
--
-- The real import. The four participation cases are all present in the sample
-- data at this meeting: abc123 is 'absent', bde456 is 'attended', klj39 is
-- 'contributed', and jlb325 and crt43 have no engagement row at all.
--
SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged, import_id, dry_run
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"structuredquerylang","netid":"ABC123","points":13},
              {"meeting_slug":"structuredquerylang","netid":"bde456","points":6.5},
              {"meeting_slug":"structuredquerylang","netid":"klj39","points":13},
              {"meeting_slug":"structuredquerylang","netid":"jlb325","points":13},
              {"meeting_slug":"structuredquerylang","netid":"crt43","points":0}]''::jsonb,
            p_mark_attended => true,
            p_import_id => ''sql-quiz-first-sitting'',
            p_reason => ''SQL quiz''
        )
    ', ' VALUES (5, 0, 0, 5, 2, 1, 2, ''sql-quiz-first-sitting''::text, false) ', 'import_quiz_results should insert grades, create the submissions they need, and mark attendance')
;
--
-- The bug this replaces. ensure_student_engagement_rows() already wrote an
-- 'absent' row for abc123, so the loaders' INSERT ... ON CONFLICT DO NOTHING
-- always hit that row and left it saying 'absent'. Nobody was ever marked
-- attended by a quiz import.
--
SELECT
    "is"((
        SELECT participation::text
        FROM api.engagements
        WHERE
            user_id = 1
            AND meeting_slug = 'structuredquerylang'
    ), 'attended', 'an absent student in the batch should be promoted to attended')
; SELECT
    "is"((
        SELECT participation::text
        FROM api.engagements
        WHERE
            user_id = 3
            AND meeting_slug = 'structuredquerylang'
    ), 'contributed', 'a contributed judgement should survive the import rather than be downgraded')
; SELECT
    "is"((
        SELECT participation::text
        FROM api.engagements
        WHERE
            user_id = 2
            AND meeting_slug = 'structuredquerylang'
    ), 'attended', 'an already attended student should be left as attended')
; SELECT results_eq('
        SELECT user_id, participation::text
        FROM api.engagements
        WHERE meeting_slug = ''structuredquerylang'' AND user_id IN (4, 5)
        ORDER BY user_id
    ', ' VALUES (4, ''attended''::text), (5, ''attended''::text) ', 'a person in the batch with no engagement row should get one saying attended')
;
-- Only the imported batch. abc123 is 'absent' at intro and at
-- entrepreneurship-woot, and neither meeting was in the payload.
SELECT results_eq('
        SELECT meeting_slug, participation::text
        FROM api.engagements
        WHERE user_id = 1 AND meeting_slug <> ''structuredquerylang''
        ORDER BY meeting_slug
    ', ' VALUES (''entrepreneurship-woot''::text, ''absent''::text), (''intro''::text, ''absent''::text) ', 'attendance should touch only the meeting in the imported batch')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.engagements
        WHERE
            meeting_slug = 'intro'
            AND user_id IN (4, 5)
    ), 0, 'attendance should touch only the people in the imported batch')
;
--
-- Grades
--
SELECT results_eq('
        SELECT points, points_possible
        FROM api.quiz_grades
        WHERE quiz_id = 2 AND user_id = 2
    ', ' VALUES (6.5::real, 13::smallint) ', 'import_quiz_results should store the final points it was handed')
; SELECT results_eq('
        SELECT event_type, operation, source, reason, import_id
        FROM api.quiz_grade_events
        WHERE quiz_id = 2 AND user_id = 1
    ', ' VALUES (''recorded''::text, ''insert''::text, ''api.import_quiz_results''::text, ''SQL quiz''::text, ''sql-quiz-first-sitting''::text) ', 'quiz grade history should record the import source, reason, and import id')
;
--
-- Re-run
--
SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"structuredquerylang","netid":"abc123","points":13},
              {"meeting_slug":"structuredquerylang","netid":"bde456","points":6.5},
              {"meeting_slug":"structuredquerylang","netid":"klj39","points":13},
              {"meeting_slug":"structuredquerylang","netid":"jlb325","points":13},
              {"meeting_slug":"structuredquerylang","netid":"crt43","points":0}]''::jsonb,
            p_mark_attended => true
        )
    ', ' VALUES (0, 0, 5, 0, 0, 0, 5) ', 'rerunning the same import should report every row as unchanged and do no attendance work')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.quiz_grade_events
        WHERE quiz_id = 2
    ), 5, 'rerunning the same import should not append redundant correction events')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.quiz_submissions
        WHERE quiz_id = 2
    ), 5, 'rerunning the same import should not create a second submission')
;
--
-- Corrections
--
SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"structuredquerylang","netid":"bde456","points":8,"description":"regraded q3"}]''::jsonb,
            p_reason => ''Regrade request''
        )
    ', ' VALUES (0, 1, 0) ', 'a changed score should be reported as an update')
; SELECT results_eq('
        SELECT event_type, points, reason
        FROM api.quiz_grade_events
        WHERE quiz_id = 2 AND user_id = 2
        ORDER BY id DESC
        LIMIT 1
    ', ' VALUES (''corrected''::text, 8::real, ''Regrade request''::text) ', 'a changed score should append one correction event carrying its reason')
;
--
-- Zero is a real score, and an absent description is not an instruction to
-- erase the one already there.
--
SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"structuredquerylang","netid":"bde456","points":0}]''::jsonb
        )
    ', ' VALUES (0, 1, 0) ', 'a zero score should be imported like any other score')
; SELECT results_eq('
        SELECT points, description
        FROM api.quiz_grades
        WHERE quiz_id = 2 AND user_id = 2
    ', ' VALUES (0::real, ''regraded q3''::text) ', 'an import without a description key should leave the existing description alone')
; SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"structuredquerylang","netid":"bde456","points":0,"description":null}]''::jsonb
        )
    ', ' VALUES (0, 1, 0) ', 'an explicit null description should be reported as a change')
; SELECT
    "is"((
        SELECT description
        FROM api.quiz_grades
        WHERE
            quiz_id = 2
            AND user_id = 2
    ), NULL, 'an explicit null description should clear the existing description')
;
--
-- Whitespace and case, because these arrive from spreadsheets
--
SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"  structuredquerylang  ","netid":"  BDE456  ","points":0}]''::jsonb
        )
    ', ' VALUES (0, 0, 1) ', 'padded and upper-case keys should resolve to the same grade rather than a new one')
; SELECT
    isnt((
        SELECT import_id
        FROM api.import_quiz_results('[{"meeting_slug":"structuredquerylang","netid":"bde456","points":0}]'::jsonb)
    ), NULL, 'import_quiz_results should generate an import id when the caller supplies none')
;
--
-- A grade that already exists needs no submission created for it, and a 'led'
-- judgement outranks presence just as 'contributed' does.
--
SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"entrepreneurship-woot","netid":"klj39","points":13}]''::jsonb,
            p_mark_attended => true
        )
    ', ' VALUES (1, 0, 0, 1, 0, 0, 1) ', 'a led judgement should count as unchanged attendance rather than a promotion')
; SELECT
    "is"((
        SELECT participation::text
        FROM api.engagements
        WHERE
            user_id = 3
            AND meeting_slug = 'entrepreneurship-woot'
    ), 'led', 'a led judgement should survive the import rather than be downgraded')
;
--
-- The transaction-local grade event settings must not outlive the import
--
RESET role
; UPDATE data.quiz_grade
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
    ', ' VALUES (''data.quiz_grade''::text, NULL::text, NULL::text) ', 'a later hand edit should not inherit the import source, reason, or import id')
;
--
-- The TA path (#389). jlb325 (user 4) is the sample TA. A fresh student gets
-- absent engagement rows for every meeting from ensure_student_engagement_rows,
-- so the TA import has a clean slate to record on. Grades at this point:
-- abc123 has 12 on intro (quiz 1) after the hand edit above.
--
INSERT INTO data."user" (id, netid, name, nickname, role)
VALUES (9002, 'nk77', 'New Kid', 'fresh-fox', 'student')
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"nk77","points":10}]''::jsonb
        )
    ', '%requires a non-blank p_reason from a TA%', 'a TA import without a reason should be refused')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"nk77","points":10}]''::jsonb,
            p_reason => ''   ''
        )
    ', '%requires a non-blank p_reason from a TA%', 'a TA import with a whitespace reason should be refused')
;
-- entrepreneurship-woot holds quiz 3, still a draft, which api.quizzes hides
-- from TAs. The import hides it the same way: the reply is the one a meeting
-- with no quiz gets, so it says nothing about whether a draft exists.
SELECT throws_ok('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"entrepreneurship-woot","netid":"nk77","points":10}]''::jsonb,
            p_reason => ''Quiz 3''
        )
    ', '23503', 'import_quiz_results does not know a quiz for meeting slug: entrepreneurship-woot', 'a TA should not be able to record grades on a draft quiz, and is told nothing more than for a meeting with no quiz')
; SELECT throws_ok('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"server-side-apps","netid":"nk77","points":10}]''::jsonb,
            p_reason => ''Quiz 3''
        )
    ', '23503', 'import_quiz_results does not know a quiz for meeting slug: server-side-apps', 'a meeting with no quiz gets the same reply for a TA')
;
-- Only students. jlb325 is the TA themself, klj39 is faculty, crt43 an
-- observer.
SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"nk77","points":10},
              {"meeting_slug":"intro","netid":"jlb325","points":13},
              {"meeting_slug":"intro","netid":"klj39","points":13},
              {"meeting_slug":"intro","netid":"crt43","points":13}]''::jsonb,
            p_reason => ''Quiz 1''
        )
    ', '%a TA can only record grades for students, not for: crt43, jlb325, klj39%', 'a TA should not be able to grade themself, faculty, or an observer, and the batch names them')
; RESET role
; SELECT is_empty(' SELECT quiz_id FROM data.quiz_grade WHERE user_id IN (3, 4, 5, 9002) AND quiz_id = 1 ', 'a TA batch naming a non-student should write no grade at all')
; SELECT is_empty(' SELECT quiz_id FROM data.quiz_submission WHERE user_id IN (3, 4, 5, 9002) AND quiz_id = 1 ', 'a TA batch naming a non-student should create no submission')
; SELECT is_empty(' SELECT id FROM data.quiz_grade_event WHERE user_id IN (3, 4, 5, 9002) AND quiz_id = 1 ', 'a TA batch naming a non-student should append no event')
; SET LOCAL role TO ta
; SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged, dry_run
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"nk77","points":10}]''::jsonb,
            p_mark_attended => true,
            p_dry_run => true,
            p_reason => ''Quiz 1 from quiz.som.chat''
        )
    ', ' VALUES (1, 0, 0, 1, 0, 1, 0, true) ', 'a TA dry run should report the planned grade, submission, and attendance work')
; RESET role
; SELECT is_empty(' SELECT quiz_id FROM data.quiz_grade WHERE user_id = 9002 ', 'a TA dry run should write no grade')
; SELECT is_empty(' SELECT quiz_id FROM data.quiz_submission WHERE user_id = 9002 ', 'a TA dry run should create no submission')
; SELECT
    "is"((
        SELECT participation::text
        FROM data.engagement
        WHERE
            user_id = 9002
            AND meeting_slug = 'intro'
    ), 'absent', 'a TA dry run should not promote attendance')
; SET LOCAL role TO ta
; SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged, import_id, dry_run
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"nk77","points":10}]''::jsonb,
            p_mark_attended => true,
            p_import_id => ''ta-quiz-1'',
            p_reason => ''Quiz 1 from quiz.som.chat''
        )
    ', ' VALUES (1, 0, 0, 1, 0, 1, 0, ''ta-quiz-1''::text, false) ', 'a TA should be able to record a new grade, its submission, and attendance')
; SELECT
    "is"((
        SELECT participation::text
        FROM api.engagements
        WHERE
            user_id = 9002
            AND meeting_slug = 'intro'
    ), 'attended', 'a TA import with p_mark_attended should promote the student to attended')
;
-- The grade is the student's to see.
SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "9002"
; SELECT results_eq('
        SELECT quiz_id, points, points_possible
        FROM api.quiz_grades
    ', ' VALUES (1, 10::real, 13::smallint) ', 'the grade a TA recorded should appear for the student')
;
-- The audit event names the TA, not the owner role, and carries the reason
-- and the import id.
RESET role
; SELECT results_eq('
        SELECT event_type, operation, created_by_user_id, source, reason, import_id
        FROM data.quiz_grade_event
        WHERE user_id = 9002
    ', ' VALUES (''recorded''::text, ''insert''::text, 4, ''api.import_quiz_results''::text, ''Quiz 1 from quiz.som.chat''::text, ''ta-quiz-1''::text) ', 'a TA import should be audited under the TA''s user id with its reason and import id')
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count, import_id IS NOT NULL
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"nk77","points":10}]''::jsonb,
            p_reason => ''Quiz 1 again''
        )
    ', ' VALUES (0, 0, 1, true) ', 'a TA re-run of an identical batch should be unchanged, not a change, with an import id generated')
;
-- Record once: any row that would change an existing grade refuses the
-- whole batch, up, down, or description only, and names the row. abc123 has
-- 12 on intro; nk77 has 10 with no description.
SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"nk77","points":10},
              {"meeting_slug":"intro","netid":"abc123","points":13},
              {"meeting_slug":"structuredquerylang","netid":"nk77","points":5}]''::jsonb,
            p_reason => ''Quiz 1 corrections''
        )
    ', '%a TA import records grades once and this batch would change an existing grade for: intro/abc123;%', 'a TA batch that would raise an existing grade should be refused whole, naming the row')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":11}]''::jsonb,
            p_reason => ''Quiz 1 corrections''
        )
    ', '%would change an existing grade for: intro/abc123;%', 'a TA batch that would lower an existing grade should be refused')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"nk77","points":10,"description":"missed q2"}]''::jsonb,
            p_reason => ''Quiz 1 corrections''
        )
    ', '%would change an existing grade for: intro/nk77;%', 'a TA batch that would change only a description should be refused')
; SELECT throws_like('
        SELECT * FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"abc123","points":13},
              {"meeting_slug":"intro","netid":"bde456","points":1}]''::jsonb,
            p_dry_run => true,
            p_reason => ''Quiz 1 corrections''
        )
    ', '%would change an existing grade for: intro/abc123, intro/bde456;%', 'a TA dry run should refuse the same batch and name every row')
; RESET role
; SELECT is_empty(' SELECT quiz_id FROM data.quiz_grade WHERE user_id = 9002 AND quiz_id = 2 ', 'a refused TA batch should write none of its rows, the new grade included')
; SELECT results_eq(' SELECT points, description FROM data.quiz_grade WHERE quiz_id = 1 AND user_id IN (1, 9002) ORDER BY user_id ', ' VALUES (12::real, NULL::text), (10::real, NULL::text) ', 'a refused TA batch should leave the existing grades as they were')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.quiz_grade_event
        WHERE user_id = 9002
    ), 1, 'a refused TA batch and an identical re-run should append no events')
;
-- The same batch from faculty is a correction, with no reason required.
SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT results_eq('
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count
        FROM api.import_quiz_results(
            ''[{"meeting_slug":"intro","netid":"nk77","points":10},
              {"meeting_slug":"intro","netid":"abc123","points":13},
              {"meeting_slug":"structuredquerylang","netid":"nk77","points":5}]''::jsonb
        )
    ', ' VALUES (1, 1, 1, 1) ', 'a faculty batch should change an existing grade, with the reason still optional')
;
--
-- The engagement row bound (#346) applies to TA claims, definer or not, and
-- the import refuses up front rather than rolling back after the grades went
-- in. The grade tables carry no bound. 65 fresh students, each with an
-- absent row at every meeting. Each call below is its own request, so the
-- budget is reset before it the way api.check_request_jwt does.
--
RESET role
; INSERT INTO data."user" (id, netid, name, nickname, role)
SELECT
    9100 + i, 'bnd' || i, 'Bound Student ' || i,
    ('bound-' || chr((96 + ((i - 1) / 26)) + 1)) || chr((96 + ((i - 1) % 26)) + 1),
    'student'
FROM generate_series(1, 65) i
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT request.reset_row_bound_counters()
; SELECT throws_ok('
        SELECT * FROM api.import_quiz_results(
            (SELECT jsonb_agg(jsonb_build_object(''meeting_slug'', ''structuredquerylang'', ''netid'', ''bnd'' || i, ''points'', 1))
             FROM generate_series(1, 65) AS i),
            p_mark_attended => true,
            p_reason => ''Quiz 2, whole section''
        )
    ', 'PT400', 'import_quiz_results: a TA request may mark attendance for at most 64 people and this batch would mark 65; send it in batches of that size with the same p_import_id, or without p_mark_attended', 'a TA batch that would mark more attendance than one request may is refused before anything is written')
; SELECT request.reset_row_bound_counters()
; SELECT throws_ok('
        SELECT * FROM api.import_quiz_results(
            (SELECT jsonb_agg(jsonb_build_object(''meeting_slug'', ''structuredquerylang'', ''netid'', ''bnd'' || i, ''points'', 1))
             FROM generate_series(1, 65) AS i),
            p_mark_attended => true,
            p_dry_run => true,
            p_reason => ''Quiz 2, whole section''
        )
    ', 'PT400', NULL, 'a TA dry run refuses the same batch')
; RESET role
; SELECT is_empty(' SELECT quiz_id FROM data.quiz_grade WHERE user_id BETWEEN 9101 AND 9165 ', 'the refused batch wrote no grades')
; SELECT is_empty(' SELECT user_id FROM data.engagement WHERE user_id BETWEEN 9101 AND 9165 AND participation <> ''absent'' ', 'the refused batch marked nobody attended')
; SET LOCAL role TO ta
; SELECT request.reset_row_bound_counters()
; SELECT results_eq('
        SELECT inserted_count, attendance_inserted, attendance_updated, attendance_unchanged
        FROM api.import_quiz_results(
            (SELECT jsonb_agg(jsonb_build_object(''meeting_slug'', ''structuredquerylang'', ''netid'', ''bnd'' || i, ''points'', 1))
             FROM generate_series(1, 64) AS i),
            p_mark_attended => true,
            p_reason => ''Quiz 2, first 64''
        )
    ', ' VALUES (64, 0, 64, 0) ', 'a TA batch marking exactly the bound''s worth of attendance goes through')
; SELECT request.reset_row_bound_counters()
; SELECT results_eq('
        SELECT inserted_count, unchanged_count, attendance_inserted, attendance_updated, attendance_unchanged
        FROM api.import_quiz_results(
            (SELECT jsonb_agg(jsonb_build_object(''meeting_slug'', ''structuredquerylang'', ''netid'', ''bnd'' || i, ''points'', 1))
             FROM generate_series(1, 65) AS i),
            p_mark_attended => true,
            p_reason => ''Quiz 2, the rest''
        )
    ', ' VALUES (1, 64, 0, 1, 64) ', 'the rest of the section, re-sent with the first batch, marks only what is left to mark')
; SELECT request.reset_row_bound_counters()
; SELECT results_eq('
        SELECT inserted_count
        FROM api.import_quiz_results(
            (SELECT jsonb_agg(jsonb_build_object(''meeting_slug'', ''intro'', ''netid'', ''bnd'' || i, ''points'', 1))
             FROM generate_series(1, 65) AS i),
            p_reason => ''Quiz 1, whole section''
        )
    ', ' VALUES (65) ', 'a TA batch of 65 grades without attendance is not bounded')
;
--
-- The policies are the backstop. A throwaway definer owned by quiz_importer,
-- with none of the import's checks, stands in for a regression in them or
-- for a later function owned by the same role. Under a TA claim the row
-- policies alone must refuse a non-student target, a draft quiz, and a
-- change to an existing grade, and still admit what the import writes.
-- Faculty stay unrestricted. Rolled back with the rest of the file.
--
-- User 9003 is a fresh student with no submission anywhere and an absent
-- engagement row at every meeting; the faculty member (3) and the TA (4) get
-- a submission on quiz 1 from the superuser, so that a grade insert for
-- either reaches the grade policy rather than failing on the foreign key.
--
RESET role
; CREATE FUNCTION pg_temp.write_as_importer(p_statement text) RETURNS void SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
BEGIN
    EXECUTE p_statement;
END;
$$
; ALTER FUNCTION pg_temp.write_as_importer(text) OWNER TO quiz_importer
; INSERT INTO data."user" (id, netid, name, nickname, role)
VALUES (9003, 'nk78', 'Newer Kid', 'fresh-owl', 'student')
; INSERT INTO data.quiz_submission (quiz_id, user_id)
VALUES (1, 3), (1, 4)
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT throws_ok(' SELECT pg_temp.write_as_importer(''INSERT INTO data.quiz_grade (quiz_id, user_id, points_possible, points) VALUES (1, 3, 13, 13)'') ', '42501', NULL, 'the quiz_grade INSERT policy alone refuses a TA-claimed definer writing a grade for a faculty member')
; SELECT throws_ok(' SELECT pg_temp.write_as_importer(''INSERT INTO data.quiz_grade (quiz_id, user_id, points_possible, points) VALUES (1, 4, 13, 13)'') ', '42501', NULL, 'the quiz_grade INSERT policy alone refuses a TA grading themself')
; SELECT throws_ok(' SELECT pg_temp.write_as_importer(''INSERT INTO data.quiz_submission (quiz_id, user_id) VALUES (2, 3)'') ', '42501', NULL, 'the quiz_submission INSERT policy alone refuses a TA-claimed definer creating a submission for a faculty member')
; SELECT throws_ok(' SELECT pg_temp.write_as_importer(''INSERT INTO data.quiz_submission (quiz_id, user_id) VALUES (3, 9003)'') ', '42501', NULL, 'the quiz_submission INSERT policy alone refuses a TA-claimed definer creating a submission on a draft quiz')
; SELECT throws_ok(' SELECT pg_temp.write_as_importer(''INSERT INTO data.quiz_grade (quiz_id, user_id, points_possible, points) VALUES (3, 9003, 13, 13)'') ', '42501', NULL, 'the quiz_grade INSERT policy alone refuses a TA-claimed definer writing a grade on a draft quiz')
; SELECT throws_ok(' SELECT pg_temp.write_as_importer(''INSERT INTO data.engagement (user_id, meeting_slug, participation) VALUES (3, ''''server-side-apps'''', ''''attended'''')'') ', '42501', NULL, 'the engagement INSERT policy alone refuses a TA-claimed definer marking a faculty member attended')
; SELECT throws_ok(' SELECT pg_temp.write_as_importer(''UPDATE data.engagement SET participation = ''''attended'''' WHERE user_id = 9003 AND meeting_slug = ''''entrepreneurship-woot'''''') ', '42501', NULL, 'the engagement UPDATE policy alone refuses a TA-claimed definer marking attendance at a draft quiz''s meeting')
; SELECT throws_ok(' SELECT pg_temp.write_as_importer(''UPDATE data.engagement SET participation = ''''led'''' WHERE user_id = 9003 AND meeting_slug = ''''structuredquerylang'''''') ', '42501', NULL, 'the engagement UPDATE policy alone refuses a TA-claimed definer writing anything but attended')
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''UPDATE data.quiz_grade SET points = 0 WHERE quiz_id = 1 AND user_id = 1'') ', 'a TA-claimed definer updating an existing grade runs without error...')
; RESET role
; SELECT results_eq(' SELECT points FROM data.quiz_grade WHERE quiz_id = 1 AND user_id = 1 ', ' VALUES (13::real) ', '...but the quiz_grade UPDATE policy alone lets it change nothing')
; SET LOCAL role TO ta
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''INSERT INTO data.quiz_submission (quiz_id, user_id) VALUES (2, 9003)'') ', 'the policies alone admit a submission for a student on a published quiz')
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''INSERT INTO data.quiz_grade (quiz_id, user_id, points_possible, points) VALUES (2, 9003, 13, 13)'') ', 'the policies alone admit a grade for a student on a published quiz')
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''UPDATE data.engagement SET participation = ''''attended'''' WHERE user_id = 9003 AND meeting_slug = ''''structuredquerylang'''''') ', 'the policies alone admit promoting a student to attended at a published quiz''s meeting')
; RESET role
; SELECT results_eq(' SELECT participation::text FROM data.engagement WHERE user_id = 9003 AND meeting_slug = ''structuredquerylang'' ', ' VALUES (''attended''::text) ', 'and that promotion took effect')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT lives_ok(' SELECT pg_temp.write_as_importer(''INSERT INTO data.quiz_grade (quiz_id, user_id, points_possible, points) VALUES (1, 3, 13, 13)'') ', 'the policies leave a faculty claim unrestricted, as through the api views')
;
-- Nothing else opened for TAs: the views stay faculty-only for writes, and
-- the history stays faculty-only to read.
SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT throws_like(' INSERT INTO api.quiz_grades (quiz_id, user_id, points) VALUES (2, 9002, 13) ', '%permission denied%', 'a TA should not be able to insert a quiz grade directly')
; SELECT throws_like(' UPDATE api.quiz_grades SET points = 13 WHERE quiz_id = 2 AND user_id = 9002 ', '%permission denied%', 'a TA should not be able to update a quiz grade directly')
; SELECT throws_like(' DELETE FROM api.quiz_grades WHERE quiz_id = 2 AND user_id = 9002 ', '%permission denied%', 'a TA should not be able to delete a quiz grade directly')
; SELECT throws_like(' INSERT INTO api.quiz_submissions (quiz_id, user_id) VALUES (3, 9002) ', '%permission denied%', 'a TA should not be able to insert a quiz submission directly')
; SELECT throws_like(' UPDATE api.quiz_submissions SET user_id = 9002 WHERE quiz_id = 2 AND user_id = 4 ', '%permission denied%', 'a TA should not be able to update a quiz submission directly')
; SELECT throws_like(' DELETE FROM api.quiz_submissions WHERE quiz_id = 2 AND user_id = 9002 ', '%permission denied%', 'a TA should not be able to delete a quiz submission directly')
; SELECT throws_like(' SELECT id FROM api.quiz_grade_events ', '%permission denied%', 'a TA should not be able to read quiz grade history')
; RESET role
; SELECT *
FROM finish()
