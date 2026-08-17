begin;
select plan(46);

SELECT function_privs_are(
    'api', 'import_assignment_grades',
    ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'],
    'anonymous', ARRAY[]::text[],
    'anonymous should not be able to execute api.import_assignment_grades'
);

SELECT function_privs_are(
    'api', 'import_assignment_grades',
    ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'],
    'student', ARRAY[]::text[],
    'students should not be able to execute api.import_assignment_grades'
);

SELECT function_privs_are(
    'api', 'import_assignment_grades',
    ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'],
    'ta', ARRAY[]::text[],
    'tas should not be able to execute api.import_assignment_grades'
);

SELECT function_privs_are(
    'api', 'import_assignment_grades',
    ARRAY['jsonb', 'boolean', 'boolean', 'text', 'text'],
    'faculty', ARRAY['EXECUTE'],
    'faculty should be able to execute api.import_assignment_grades'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT throws_like(
    $$ SELECT * FROM api.import_assignment_grades('[]'::jsonb) $$,
    '%permission denied%',
    'students should not be able to import assignment grades'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';

--
-- Payload shape guards
--

SELECT throws_like(
    $$ SELECT * FROM api.import_assignment_grades('[]'::jsonb) $$,
    '%refuses to import an empty grade list%',
    'import_assignment_grades should reject an empty grade list'
);

SELECT throws_like(
    $$ SELECT * FROM api.import_assignment_grades('{"netid":"abc123"}'::jsonb) $$,
    '%expects a JSON array%',
    'import_assignment_grades should reject non-array JSON'
);

SELECT throws_like(
    $$ SELECT * FROM api.import_assignment_grades('"just-a-string"'::jsonb) $$,
    '%expects a JSON array%',
    'import_assignment_grades should reject scalar JSON input'
);

SELECT throws_like(
    $$ SELECT * FROM api.import_assignment_grades('["abc123"]'::jsonb) $$,
    '%expects a JSON object for every grade%',
    'import_assignment_grades should reject array elements that are not objects'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'assignment_slug', 'exam-1',
                        'netid', 'cardinality' || i,
                        'points', 1
                    )
                )
                FROM generate_series(1, 2001) AS i
            )
        )
    $$,
    '%accepts at most 2000 grades%',
    'import_assignment_grades should reject more than 2000 grades'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            jsonb_build_array(
                jsonb_build_object(
                    'assignment_slug', 'exam-1',
                    'netid', 'abc123',
                    'points', 1,
                    'description', repeat('x', 4194305)
                )
            )
        )
    $$,
    '%payload exceeds the 4 MB limit%',
    'import_assignment_grades should reject payloads larger than 4 MB'
);

--
-- Row-level validation. Every one of these fails the whole import instead of
-- skipping the offending row, which is the behaviour that differs from the
-- CSV loader this replaces.
--

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":1},
              {"assignment_slug":"exam-1","netid":"","points":1}]'::jsonb
        )
    $$,
    '%requires assignment_slug and netid on every grade, missing at position: 2%',
    'import_assignment_grades should name the position of a row missing its key'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123"}]'::jsonb
        )
    $$,
    '%a missing or null score is not a zero: exam-1/abc123%',
    'import_assignment_grades should reject an absent score rather than read it as zero'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":null}]'::jsonb
        )
    $$,
    '%a missing or null score is not a zero: exam-1/abc123%',
    'import_assignment_grades should reject a null score rather than read it as zero'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":"45"}]'::jsonb
        )
    $$,
    '%requires numeric points: exam-1/abc123%',
    'import_assignment_grades should reject a non-numeric score'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":51}]'::jsonb
        )
    $$,
    '%points between 0 and the assignment points_possible, out of range for: exam-1/abc123%',
    'import_assignment_grades should reject a score above points_possible'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":-1}]'::jsonb
        )
    $$,
    '%points between 0 and the assignment points_possible, out of range for: exam-1/abc123%',
    'import_assignment_grades should reject a negative score'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":1},
              {"assignment_slug":"exam-1","netid":"ABC123","points":2}]'::jsonb
        )
    $$,
    '%duplicate assignment_slug/netid key: exam-1/abc123%',
    'import_assignment_grades should reject duplicate natural keys rather than take the last write'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"no-such-assignment","netid":"abc123","points":1}]'::jsonb
        )
    $$,
    '%does not know assignment slug: no-such-assignment%',
    'import_assignment_grades should name an unknown assignment slug'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":1},
              {"assignment_slug":"exam-1","netid":"nosuch999","points":1}]'::jsonb
        )
    $$,
    '%does not know netid: nosuch999%',
    'import_assignment_grades should name an unknown netid instead of dropping the row'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_grades WHERE assignment_slug = 'exam-1'),
    0,
    'a rejected import should leave no assignment grades behind'
);

--
-- Team assignments. project-update-1 is the team assignment in the sample data,
-- and users 1 and 3 share the bright-fog team.
--

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"project-update-1","netid":"jlb325","points":1}]'::jsonb
        )
    $$,
    '%cannot reach a team submission for a student with no team: project-update-1/jlb325%',
    'import_assignment_grades should reject a team grade for a student with no team'
);

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"project-update-1","netid":"abc123","points":70},
              {"assignment_slug":"project-update-1","netid":"klj39","points":70}]'::jsonb
        )
    $$,
    '%more than one netid for the same team submission%',
    'import_assignment_grades should reject two teammates resolving to one team submission'
);

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count
        FROM api.import_assignment_grades(
            '[{"assignment_slug":"project-update-1","netid":"abc123","points":70}]'::jsonb
        )
    $$,
    $$ VALUES (0, 1, 0, 0) $$,
    'import_assignment_grades should reach an existing team submission through one teammate netid'
);

SELECT is(
    (SELECT points FROM api.assignment_grades WHERE assignment_submission_id = 4),
    70::real,
    'a team import should write the grade on the team submission'
);

--
-- Missing submissions. data.assignment_grade cannot exist without one, so a
-- paper exam has to create it.
--

SELECT throws_like(
    $$
        SELECT * FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":1}]'::jsonb,
            p_create_missing_submissions => false
        )
    $$,
    '%found no assignment submission for: exam-1/abc123%',
    'import_assignment_grades should fail rather than skip when told not to create submissions'
);

--
-- Dry run
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count, dry_run
        FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":45.5,"description":"missed q7"},
              {"assignment_slug":"team-selection","netid":"abc123","points":50,"description":"Foo bar bax boo this is your comment"}]'::jsonb,
            p_dry_run => true
        )
    $$,
    $$ VALUES (1, 0, 1, 1, true) $$,
    'a dry run should report planned inserts, unchanged rows, and planned submissions'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_submissions WHERE assignment_slug = 'exam-1'),
    0,
    'a dry run should not create assignment submissions'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_grades WHERE assignment_slug = 'exam-1'),
    0,
    'a dry run should not write assignment grades'
);

--
-- Import, then re-import
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count, import_id, dry_run
        FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"ABC123","points":45.5,"description":"missed q7"}]'::jsonb,
            p_import_id => 'exam-1-first-sitting',
            p_reason => 'Exam 1'
        )
    $$,
    $$ VALUES (1, 0, 0, 1, 'exam-1-first-sitting'::text, false) $$,
    'import_assignment_grades should insert a grade and create the submission it needs'
);

SELECT results_eq(
    $$
        SELECT is_team, user_id, submitter_user_id
        FROM api.assignment_submissions
        WHERE assignment_slug = 'exam-1'
    $$,
    $$ VALUES (false, 1, 1) $$,
    'a created individual submission should belong to the student, not to the importing faculty'
);

SELECT results_eq(
    $$
        SELECT points, points_possible, description
        FROM api.assignment_grades
        WHERE assignment_slug = 'exam-1'
    $$,
    $$ VALUES (45.5::real, 50::smallint, 'missed q7'::text) $$,
    'import_assignment_grades should store the final points it was handed'
);

SELECT results_eq(
    $$
        SELECT event_type, operation, source, reason, import_id
        FROM api.assignment_grade_events
        WHERE assignment_slug = 'exam-1'
    $$,
    $$ VALUES ('recorded'::text, 'insert'::text, 'api.import_assignment_grades'::text, 'Exam 1'::text, 'exam-1-first-sitting'::text) $$,
    'grade history should record the import source, reason, and import id'
);

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, submission_created_count
        FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":45.5,"description":"missed q7"}]'::jsonb
        )
    $$,
    $$ VALUES (0, 0, 1, 0) $$,
    'rerunning the same import should report the row as unchanged'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_grade_events WHERE assignment_slug = 'exam-1'),
    1,
    'rerunning the same import should not append a redundant correction event'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_submissions WHERE assignment_slug = 'exam-1'),
    1,
    'rerunning the same import should not create a second submission'
);

--
-- Corrections
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":48,"description":"regraded q7"}]'::jsonb,
            p_reason => 'Regrade request'
        )
    $$,
    $$ VALUES (0, 1, 0) $$,
    'a changed score should be reported as an update'
);

SELECT results_eq(
    $$
        SELECT event_type, points, reason
        FROM api.assignment_grade_events
        WHERE assignment_slug = 'exam-1'
        ORDER BY id DESC
        LIMIT 1
    $$,
    $$ VALUES ('corrected'::text, 48::real, 'Regrade request'::text) $$,
    'a changed score should append one correction event carrying its reason'
);

--
-- Zero is a real score, and an absent description is not an instruction to
-- erase the one already there.
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":0}]'::jsonb
        )
    $$,
    $$ VALUES (0, 1, 0) $$,
    'a zero score should be imported like any other score'
);

SELECT results_eq(
    $$
        SELECT points, description
        FROM api.assignment_grades
        WHERE assignment_slug = 'exam-1'
    $$,
    $$ VALUES (0::real, 'regraded q7'::text) $$,
    'an import without a description key should leave the existing description alone'
);

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":0,"description":null}]'::jsonb
        )
    $$,
    $$ VALUES (0, 1, 0) $$,
    'an explicit null description should be reported as a change'
);

SELECT is(
    (SELECT description FROM api.assignment_grades WHERE assignment_slug = 'exam-1'),
    NULL,
    'an explicit null description should clear the existing description'
);

--
-- Whitespace and case, because these arrive from spreadsheets
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.import_assignment_grades(
            '[{"assignment_slug":"  exam-1  ","netid":"  ABC123  ","points":0}]'::jsonb
        )
    $$,
    $$ VALUES (0, 0, 1) $$,
    'padded and upper-case keys should resolve to the same grade rather than a new one'
);

SELECT isnt(
    (
        SELECT import_id
        FROM api.import_assignment_grades(
            '[{"assignment_slug":"exam-1","netid":"abc123","points":0}]'::jsonb
        )
    ),
    NULL,
    'import_assignment_grades should generate an import id when the caller supplies none'
);

--
-- The transaction-local grade event settings must not outlive the import
--

SELECT is(
    (SELECT source FROM api.assignment_grade_events ORDER BY id DESC LIMIT 1),
    'api.import_assignment_grades'::text,
    'the last event written should still be attributed to the import'
);

RESET ROLE;
UPDATE data.assignment_grade SET points = 41 WHERE assignment_submission_id = 2;

SELECT results_eq(
    $$
        SELECT source, reason, import_id
        FROM api.assignment_grade_events
        WHERE assignment_submission_id = 2
        ORDER BY id DESC
        LIMIT 1
    $$,
    $$ VALUES ('data.assignment_grade'::text, NULL::text, NULL::text) $$,
    'a later hand edit should not inherit the import source, reason, or import id'
);

select * from finish();
rollback;
