begin;
select plan(57);

SELECT function_privs_are(
    'api', 'import_quiz_results',
    ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'],
    'anonymous', ARRAY[]::text[],
    'anonymous should not be able to execute api.import_quiz_results'
);

SELECT function_privs_are(
    'api', 'import_quiz_results',
    ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'],
    'student', ARRAY[]::text[],
    'students should not be able to execute api.import_quiz_results'
);

SELECT function_privs_are(
    'api', 'import_quiz_results',
    ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'],
    'ta', ARRAY[]::text[],
    'tas should not be able to execute api.import_quiz_results'
);

SELECT function_privs_are(
    'api', 'import_quiz_results',
    ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'],
    'faculty', ARRAY['EXECUTE'],
    'faculty should be able to execute api.import_quiz_results'
);

SELECT function_privs_are(
    'data', 'resolve_quiz_result_import', ARRAY['jsonb'],
    'student', ARRAY[]::text[],
    'students should not be able to resolve quiz import rows'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT throws_like(
    $$ SELECT * FROM api.import_quiz_results('[]'::jsonb) $$,
    '%permission denied%',
    'students should not be able to import quiz results'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';

--
-- Payload shape guards
--

SELECT throws_like(
    $$ SELECT * FROM api.import_quiz_results('[]'::jsonb) $$,
    '%refuses to import an empty result list%',
    'import_quiz_results should reject an empty result list'
);

SELECT throws_like(
    $$ SELECT * FROM api.import_quiz_results('{"netid":"abc123"}'::jsonb) $$,
    '%expects a JSON array%',
    'import_quiz_results should reject non-array JSON'
);

SELECT throws_like(
    $$ SELECT * FROM api.import_quiz_results('"just-a-string"'::jsonb) $$,
    '%expects a JSON array%',
    'import_quiz_results should reject scalar JSON input'
);

SELECT throws_like(
    $$ SELECT * FROM api.import_quiz_results('["abc123"]'::jsonb) $$,
    '%expects a JSON object for every result%',
    'import_quiz_results should reject array elements that are not objects'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'meeting_slug', 'intro',
                        'netid', 'cardinality' || i,
                        'points', 1
                    )
                )
                FROM generate_series(1, 2001) AS i
            )
        )
    $$,
    '%accepts at most 2000 results%',
    'import_quiz_results should reject more than 2000 results'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            jsonb_build_array(
                jsonb_build_object(
                    'meeting_slug', 'intro',
                    'netid', 'abc123',
                    'points', 1,
                    'description', repeat('x', 4194305)
                )
            )
        )
    $$,
    '%payload exceeds the 4 MB limit%',
    'import_quiz_results should reject payloads larger than 4 MB'
);

--
-- Row-level validation. Every one of these fails the whole import instead of
-- skipping the offending row, which is the behaviour that differs from the
-- CSV loaders this replaces.
--

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"intro","netid":"abc123","points":1},
              {"meeting_slug":"intro","netid":"","points":1}]'::jsonb
        )
    $$,
    '%requires meeting_slug and netid on every result, missing at position: 2%',
    'import_quiz_results should name the position of a row missing its key'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"intro","netid":"abc123"}]'::jsonb
        )
    $$,
    '%a missing or null score is not a zero: intro/abc123%',
    'import_quiz_results should reject an absent score rather than read it as zero'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"intro","netid":"abc123","points":null}]'::jsonb
        )
    $$,
    '%a missing or null score is not a zero: intro/abc123%',
    'import_quiz_results should reject a null score rather than read it as zero'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"intro","netid":"abc123","points":"12"}]'::jsonb
        )
    $$,
    '%requires numeric points: intro/abc123%',
    'import_quiz_results should reject a non-numeric score'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"intro","netid":"abc123","points":14}]'::jsonb
        )
    $$,
    '%points between 0 and the quiz points_possible, out of range for: intro/abc123%',
    'import_quiz_results should reject a score above points_possible'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"intro","netid":"abc123","points":-1}]'::jsonb
        )
    $$,
    '%points between 0 and the quiz points_possible, out of range for: intro/abc123%',
    'import_quiz_results should reject a negative score'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"intro","netid":"abc123","points":1},
              {"meeting_slug":"intro","netid":"ABC123","points":2}]'::jsonb
        )
    $$,
    '%duplicate meeting_slug/netid key: intro/abc123%',
    'import_quiz_results should reject duplicate natural keys rather than take the last write'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"no-such-meeting","netid":"abc123","points":1}]'::jsonb
        )
    $$,
    '%does not know a quiz for meeting slug: no-such-meeting%',
    'import_quiz_results should name an unknown meeting slug'
);

-- server-side-apps is a real meeting with no quiz. Unimportable for the same
-- reason as a meeting that does not exist, and named the same way.
SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"server-side-apps","netid":"abc123","points":1}]'::jsonb
        )
    $$,
    '%does not know a quiz for meeting slug: server-side-apps%',
    'import_quiz_results should reject a meeting that holds no quiz'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            '[{"meeting_slug":"intro","netid":"abc123","points":1},
              {"meeting_slug":"intro","netid":"nosuch999","points":1}]'::jsonb
        )
    $$,
    '%does not know netid: nosuch999%',
    'import_quiz_results should name an unknown netid instead of dropping the row'
);

SELECT is(
    (SELECT count(*)::int FROM api.quiz_grades WHERE quiz_id = 2),
    0,
    'a rejected import should leave no quiz grades behind'
);

--
-- A dry run exists so that the real import is known to be safe, so anything
-- that would fail the write has to fail the dry run identically.
--

-- The shape api.import_quiz_results parses to learn the description bound. If
-- this constraint is ever reshaped, the import silently stops pre-checking
-- description length and this test is the alarm.
SELECT is(
    (
        SELECT count(*)::int
        FROM pg_constraint grade_constraint
        JOIN pg_class grade_table ON grade_table.oid = grade_constraint.conrelid
        JOIN pg_namespace grade_schema ON grade_schema.oid = grade_table.relnamespace
        WHERE grade_schema.nspname = 'data'
        AND grade_table.relname = 'quiz_grade'
        AND grade_constraint.contype = 'c'
        AND pg_get_constraintdef(grade_constraint.oid) ~ 'octet_length\(description\) <= \d+'
    ),
    1,
    'data.quiz_grade should bound description length in the shape the import reads'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_quiz_results(
            jsonb_build_array(
                jsonb_build_object(
                    'meeting_slug', 'structuredquerylang',
                    'netid', 'abc123',
                    'points', 10,
                    'description', repeat('x', 8193)
                )
            ),
            p_dry_run => true
        )
    $$,
    '%description of at most 8192 bytes, too long for: structuredquerylang/abc123%',
    'a dry run should reject an oversized description rather than let the real write fail'
);

SELECT results_eq(
    $$
        SELECT inserted_count
        FROM api.import_quiz_results(
            jsonb_build_array(
                jsonb_build_object(
                    'meeting_slug', 'structuredquerylang',
                    'netid', 'abc123',
                    'points', 10,
                    'description', repeat('x', 8192)
                )
            ),
            p_dry_run => true
        )
    $$,
    $$ VALUES (1) $$,
    'a description exactly at the limit should still be accepted'
);

--
-- The participation ladder the attendance promotion walks. If a value is ever
-- added to data.participation_enum, someone has to decide where it sits
-- relative to 'attended', and this test is what makes them.
--

SELECT results_eq(
    $$ SELECT unnest(enum_range(NULL::data.participation_enum))::text $$,
    $$ VALUES ('absent'::text), ('attended'::text), ('contributed'::text), ('led'::text) $$,
    'data.participation_enum should hold only the values the attendance promotion has decided about'
);

--
-- Attendance is opt-in. abc123 is 'absent' at every meeting in the sample
-- data, so an import that does not ask for attendance must leave that alone.
--

SELECT results_eq(
    $$
        SELECT attendance_inserted, attendance_updated, attendance_unchanged
        FROM api.import_quiz_results(
            '[{"meeting_slug":"intro","netid":"abc123","points":13}]'::jsonb
        )
    $$,
    $$ VALUES (0, 0, 0) $$,
    'an import that does not ask for attendance should report no attendance work'
);

SELECT is(
    (SELECT participation::text FROM api.engagements WHERE user_id = 1 AND meeting_slug = 'intro'),
    'absent',
    'an import that does not ask for attendance should leave engagement alone'
);

--
-- Dry run
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged, dry_run
        FROM api.import_quiz_results(
            '[{"meeting_slug":"structuredquerylang","netid":"abc123","points":13},
              {"meeting_slug":"structuredquerylang","netid":"bde456","points":6.5},
              {"meeting_slug":"structuredquerylang","netid":"klj39","points":13},
              {"meeting_slug":"structuredquerylang","netid":"jlb325","points":13},
              {"meeting_slug":"structuredquerylang","netid":"crt43","points":0}]'::jsonb,
            p_mark_attended => true,
            p_dry_run => true
        )
    $$,
    $$ VALUES (5, 0, 0, 5, 2, 1, 2, true) $$,
    'a dry run should report planned grades, submissions, and attendance work'
);

SELECT is(
    (SELECT count(*)::int FROM api.quiz_submissions WHERE quiz_id = 2),
    0,
    'a dry run should not create quiz submissions'
);

SELECT is(
    (SELECT count(*)::int FROM api.quiz_grades WHERE quiz_id = 2),
    0,
    'a dry run should not write quiz grades'
);

SELECT is(
    (SELECT participation::text FROM api.engagements WHERE user_id = 1 AND meeting_slug = 'structuredquerylang'),
    'absent',
    'a dry run should not promote attendance'
);

SELECT is(
    (SELECT count(*)::int FROM api.engagements WHERE user_id = 4),
    0,
    'a dry run should not create engagement rows'
);

--
-- The real import. The four participation cases are all present in the sample
-- data at this meeting: abc123 is 'absent', bde456 is 'attended', klj39 is
-- 'contributed', and jlb325 and crt43 have no engagement row at all.
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged, import_id, dry_run
        FROM api.import_quiz_results(
            '[{"meeting_slug":"structuredquerylang","netid":"ABC123","points":13},
              {"meeting_slug":"structuredquerylang","netid":"bde456","points":6.5},
              {"meeting_slug":"structuredquerylang","netid":"klj39","points":13},
              {"meeting_slug":"structuredquerylang","netid":"jlb325","points":13},
              {"meeting_slug":"structuredquerylang","netid":"crt43","points":0}]'::jsonb,
            p_mark_attended => true,
            p_import_id => 'sql-quiz-first-sitting',
            p_reason => 'SQL quiz'
        )
    $$,
    $$ VALUES (5, 0, 0, 5, 2, 1, 2, 'sql-quiz-first-sitting'::text, false) $$,
    'import_quiz_results should insert grades, create the submissions they need, and mark attendance'
);

--
-- The bug this replaces. ensure_student_engagement_rows() already wrote an
-- 'absent' row for abc123, so the loaders' INSERT ... ON CONFLICT DO NOTHING
-- always hit that row and left it saying 'absent'. Nobody was ever marked
-- attended by a quiz import.
--

SELECT is(
    (SELECT participation::text FROM api.engagements WHERE user_id = 1 AND meeting_slug = 'structuredquerylang'),
    'attended',
    'an absent student in the batch should be promoted to attended'
);

SELECT is(
    (SELECT participation::text FROM api.engagements WHERE user_id = 3 AND meeting_slug = 'structuredquerylang'),
    'contributed',
    'a contributed judgement should survive the import rather than be downgraded'
);

SELECT is(
    (SELECT participation::text FROM api.engagements WHERE user_id = 2 AND meeting_slug = 'structuredquerylang'),
    'attended',
    'an already attended student should be left as attended'
);

SELECT results_eq(
    $$
        SELECT user_id, participation::text
        FROM api.engagements
        WHERE meeting_slug = 'structuredquerylang' AND user_id IN (4, 5)
        ORDER BY user_id
    $$,
    $$ VALUES (4, 'attended'::text), (5, 'attended'::text) $$,
    'a person in the batch with no engagement row should get one saying attended'
);

-- Only the imported batch. abc123 is 'absent' at intro and at
-- entrepreneurship-woot, and neither meeting was in the payload.
SELECT results_eq(
    $$
        SELECT meeting_slug, participation::text
        FROM api.engagements
        WHERE user_id = 1 AND meeting_slug <> 'structuredquerylang'
        ORDER BY meeting_slug
    $$,
    $$ VALUES ('entrepreneurship-woot'::text, 'absent'::text), ('intro'::text, 'absent'::text) $$,
    'attendance should touch only the meeting in the imported batch'
);

SELECT is(
    (SELECT count(*)::int FROM api.engagements WHERE meeting_slug = 'intro' AND user_id IN (4, 5)),
    0,
    'attendance should touch only the people in the imported batch'
);

--
-- Grades
--

SELECT results_eq(
    $$
        SELECT points, points_possible
        FROM api.quiz_grades
        WHERE quiz_id = 2 AND user_id = 2
    $$,
    $$ VALUES (6.5::real, 13::smallint) $$,
    'import_quiz_results should store the final points it was handed'
);

SELECT results_eq(
    $$
        SELECT event_type, operation, source, reason, import_id
        FROM api.quiz_grade_events
        WHERE quiz_id = 2 AND user_id = 1
    $$,
    $$ VALUES ('recorded'::text, 'insert'::text, 'api.import_quiz_results'::text, 'SQL quiz'::text, 'sql-quiz-first-sitting'::text) $$,
    'quiz grade history should record the import source, reason, and import id'
);

--
-- Re-run
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged
        FROM api.import_quiz_results(
            '[{"meeting_slug":"structuredquerylang","netid":"abc123","points":13},
              {"meeting_slug":"structuredquerylang","netid":"bde456","points":6.5},
              {"meeting_slug":"structuredquerylang","netid":"klj39","points":13},
              {"meeting_slug":"structuredquerylang","netid":"jlb325","points":13},
              {"meeting_slug":"structuredquerylang","netid":"crt43","points":0}]'::jsonb,
            p_mark_attended => true
        )
    $$,
    $$ VALUES (0, 0, 5, 0, 0, 0, 5) $$,
    'rerunning the same import should report every row as unchanged and do no attendance work'
);

SELECT is(
    (SELECT count(*)::int FROM api.quiz_grade_events WHERE quiz_id = 2),
    5,
    'rerunning the same import should not append redundant correction events'
);

SELECT is(
    (SELECT count(*)::int FROM api.quiz_submissions WHERE quiz_id = 2),
    5,
    'rerunning the same import should not create a second submission'
);

--
-- Corrections
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_quiz_results(
            '[{"meeting_slug":"structuredquerylang","netid":"bde456","points":8,"description":"regraded q3"}]'::jsonb,
            p_reason => 'Regrade request'
        )
    $$,
    $$ VALUES (0, 1, 0) $$,
    'a changed score should be reported as an update'
);

SELECT results_eq(
    $$
        SELECT event_type, points, reason
        FROM api.quiz_grade_events
        WHERE quiz_id = 2 AND user_id = 2
        ORDER BY id DESC
        LIMIT 1
    $$,
    $$ VALUES ('corrected'::text, 8::real, 'Regrade request'::text) $$,
    'a changed score should append one correction event carrying its reason'
);

--
-- Zero is a real score, and an absent description is not an instruction to
-- erase the one already there.
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_quiz_results(
            '[{"meeting_slug":"structuredquerylang","netid":"bde456","points":0}]'::jsonb
        )
    $$,
    $$ VALUES (0, 1, 0) $$,
    'a zero score should be imported like any other score'
);

SELECT results_eq(
    $$
        SELECT points, description
        FROM api.quiz_grades
        WHERE quiz_id = 2 AND user_id = 2
    $$,
    $$ VALUES (0::real, 'regraded q3'::text) $$,
    'an import without a description key should leave the existing description alone'
);

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_quiz_results(
            '[{"meeting_slug":"structuredquerylang","netid":"bde456","points":0,"description":null}]'::jsonb
        )
    $$,
    $$ VALUES (0, 1, 0) $$,
    'an explicit null description should be reported as a change'
);

SELECT is(
    (SELECT description FROM api.quiz_grades WHERE quiz_id = 2 AND user_id = 2),
    NULL,
    'an explicit null description should clear the existing description'
);

--
-- Whitespace and case, because these arrive from spreadsheets
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_quiz_results(
            '[{"meeting_slug":"  structuredquerylang  ","netid":"  BDE456  ","points":0}]'::jsonb
        )
    $$,
    $$ VALUES (0, 0, 1) $$,
    'padded and upper-case keys should resolve to the same grade rather than a new one'
);

SELECT isnt(
    (
        SELECT import_id
        FROM api.import_quiz_results(
            '[{"meeting_slug":"structuredquerylang","netid":"bde456","points":0}]'::jsonb
        )
    ),
    NULL,
    'import_quiz_results should generate an import id when the caller supplies none'
);

--
-- A grade that already exists needs no submission created for it, and a 'led'
-- judgement outranks presence just as 'contributed' does.
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count,
            attendance_inserted, attendance_updated, attendance_unchanged
        FROM api.import_quiz_results(
            '[{"meeting_slug":"entrepreneurship-woot","netid":"klj39","points":13}]'::jsonb,
            p_mark_attended => true
        )
    $$,
    $$ VALUES (1, 0, 0, 1, 0, 0, 1) $$,
    'a led judgement should count as unchanged attendance rather than a promotion'
);

SELECT is(
    (SELECT participation::text FROM api.engagements WHERE user_id = 3 AND meeting_slug = 'entrepreneurship-woot'),
    'led',
    'a led judgement should survive the import rather than be downgraded'
);

--
-- The transaction-local grade event settings must not outlive the import
--

RESET ROLE;
UPDATE data.quiz_grade SET points = 12 WHERE quiz_id = 1 AND user_id = 1;

SELECT results_eq(
    $$
        SELECT source, reason, import_id
        FROM api.quiz_grade_events
        WHERE quiz_id = 1 AND user_id = 1
        ORDER BY id DESC
        LIMIT 1
    $$,
    $$ VALUES ('data.quiz_grade'::text, NULL::text, NULL::text) $$,
    'a later hand edit should not inherit the import source, reason, or import id'
);

select * from finish();
rollback;
