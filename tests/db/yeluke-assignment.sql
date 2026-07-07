begin;
select plan(32);

SELECT view_owner_is(
    'api', 'assignments', 'api',
    'api.assignments view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignments', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.assignments"'
);

SELECT table_privs_are(
    'api', 'assignments', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.assignments"'
);

SELECT table_privs_are(
    'data', 'quiz', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select * from api.assignments',
    '%permission denied%',
    'anonymous users should not be able to use the api.assignments view'
);

set local role student;
set request.jwt.claim.role = 'student';

SELECT set_eq(
    'SELECT slug FROM api.assignments ORDER BY (slug)',
    ARRAY['exam-1', 'js-koans', 'project-update-1', 'team-selection'],
    'students should be able to select from the api.assignments view'
);

PREPARE doinsert AS INSERT INTO api.assignments (slug,points_possible,title,body,closed_at) VALUES ('foo', 23, 'foo', 'foo', '2017-12-27 14:55:50');
PREPARE badinsert1 AS INSERT INTO api.assignments (slug,points_possible,title,body,closed_at) VALUES ('fooX', 23, 'foo', 'foo', '2017-12-27 14:55:50');
PREPARE badinsert2 AS INSERT INTO api.assignments (slug,points_possible,title,body,closed_at) VALUES ('abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789XX', 23, 'foo', 'foo', '2017-12-27 14:55:50');

SELECT throws_like(
    'doinsert',
    '%permission denied%',
    'students should not be able to insert'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT lives_ok(
    'doinsert',
    'faculty should be able to insert'
);

SELECT lives_ok(
    'DELETE FROM api.assignments WHERE slug = ''foo''',
    'faculty can delete assignments'
);

SELECT throws_like(
    'badinsert1',
    '%violates check constraint%',
    'assignment slugs must be lowercase alphanumeric'
);

SELECT throws_like(
    'badinsert2',
    '%violates check constraint%',
    'assignment slugs must be less than 60 characters'
);

SELECT function_privs_are(
    'api', 'sync_assignments', ARRAY['jsonb', 'boolean', 'boolean'], 'anonymous', ARRAY[]::text[],
    'anonymous should not be able to execute api.sync_assignments'
);

SELECT function_privs_are(
    'api', 'sync_assignments', ARRAY['jsonb', 'boolean', 'boolean'], 'student', ARRAY[]::text[],
    'students should not be able to execute api.sync_assignments'
);

SELECT function_privs_are(
    'api', 'sync_assignments', ARRAY['jsonb', 'boolean', 'boolean'], 'faculty', ARRAY['EXECUTE'],
    'faculty should be able to execute api.sync_assignments'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT throws_like(
    $$ SELECT * FROM api.sync_assignments('[]'::jsonb) $$,
    '%permission denied%',
    'students should not be able to sync assignments'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT throws_like(
    $$ SELECT * FROM api.sync_assignments('[]'::jsonb) $$,
    '%refuses to sync an empty assignment list%',
    'sync_assignments should reject empty assignment lists'
);

SELECT throws_like(
    $$ SELECT * FROM api.sync_assignments('{"slug":"exam-1"}'::jsonb) $$,
    '%expects a JSON array%',
    'sync_assignments should reject non-array JSON'
);

SELECT throws_like(
    $$
        SELECT * FROM api.sync_assignments(
            '[{"slug":"exam-1","title":"Exam","points_possible":50,"body":"body","closed_at":"3018-12-27T14:55:50Z"}]'::jsonb
        )
    $$,
    '%expected fields to be an array%',
    'sync_assignments should require explicit field arrays'
);

SELECT throws_like(
    $$
        SELECT * FROM api.sync_assignments(
            '[{"slug":"same","title":"Same","points_possible":50,"body":"body","closed_at":"3018-12-27T14:55:50Z","fields":[]},
              {"slug":"same","title":"Same","points_possible":50,"body":"body","closed_at":"3018-12-27T14:55:50Z","fields":[]}]'::jsonb
        )
    $$,
    '%duplicate assignment slug%',
    'sync_assignments should reject duplicate assignment slugs'
);

SELECT throws_like(
    $$
        SELECT * FROM api.sync_assignments(
            '[{"slug":"exam-1","title":"Exam","points_possible":50,"body":"body","closed_at":"3018-12-27T14:55:50Z","fields":[
                {"slug":"same","label":"Same","help":"help","placeholder":"placeholder"},
                {"slug":"same","label":"Same","help":"help","placeholder":"placeholder"}
            ]}]'::jsonb
        )
    $$,
    '%duplicate assignment field key%',
    'sync_assignments should reject duplicate field keys per assignment'
);

SELECT results_eq(
    $$
        SELECT
            inserted_count,
            updated_count,
            unchanged_count,
            deleted_count,
            field_inserted_count,
            field_updated_count,
            field_unchanged_count,
            field_deleted_count,
            dry_run
        FROM api.sync_assignments(
            '[{"slug":"exam-1","title":"Updated Exam","points_possible":55,"is_draft":false,"is_markdown":false,"is_team":false,"body":"updated body","closed_at":"3018-12-27T14:55:50Z","fields":[
                {"slug":"url","label":"Updated repo","help":"Updated help","placeholder":"https://github.com/...","is_url":true,"is_multiline":false,"display_order":1,"pattern":"https://.*","example":"https://github.com/foo"},
                {"slug":"new-field","label":"New Field","help":"New help","placeholder":"value","is_url":false,"is_multiline":false,"display_order":2,"pattern":".*","example":"value"}
              ]},
              {"slug":"new-admin-assignment","title":"New Admin Assignment","points_possible":10,"is_draft":true,"is_markdown":false,"is_team":false,"body":"new body","closed_at":"3018-12-28T14:55:50Z","fields":[
                {"slug":"repo-url","label":"Repo URL","help":"Repo help","placeholder":"https://github.com/...","is_url":true,"is_multiline":false,"display_order":0,"pattern":"https://.*","example":"https://github.com/foo"}
              ]}]'::jsonb,
            false,
            true
        )
    $$,
    $$ VALUES (1, 1, 0, 0, 2, 1, 0, 2, true) $$,
    'dry-run sync_assignments should report planned assignment and field changes'
);

SELECT set_eq(
    'SELECT slug FROM api.assignments ORDER BY slug',
    ARRAY['exam-1', 'js-koans', 'project-update-1', 'team-selection'],
    'dry-run sync_assignments should leave assignments unchanged'
);

SELECT set_eq(
    'SELECT assignment_slug || ''/'' || slug FROM api.assignment_fields WHERE assignment_slug = ''exam-1'' ORDER BY slug',
    ARRAY['exam-1/fooword', 'exam-1/profound', 'exam-1/url'],
    'dry-run sync_assignments should leave assignment fields unchanged'
);

SELECT results_eq(
    $$
        SELECT
            inserted_count,
            updated_count,
            unchanged_count,
            deleted_count,
            field_inserted_count,
            field_updated_count,
            field_unchanged_count,
            field_deleted_count,
            dry_run
        FROM api.sync_assignments(
            '[{"slug":"exam-1","title":"Updated Exam","points_possible":55,"is_draft":false,"is_markdown":false,"is_team":false,"body":"updated body","closed_at":"3018-12-27T14:55:50Z","fields":[
                {"slug":"url","label":"Updated repo","help":"Updated help","placeholder":"https://github.com/...","is_url":true,"is_multiline":false,"display_order":1,"pattern":"https://.*","example":"https://github.com/foo"},
                {"slug":"new-field","label":"New Field","help":"New help","placeholder":"value","is_url":false,"is_multiline":false,"display_order":2,"pattern":".*","example":"value"}
              ]},
              {"slug":"new-admin-assignment","title":"New Admin Assignment","points_possible":10,"is_draft":true,"is_markdown":false,"is_team":false,"body":"new body","closed_at":"3018-12-28T14:55:50Z","fields":[
                {"slug":"repo-url","label":"Repo URL","help":"Repo help","placeholder":"https://github.com/...","is_url":true,"is_multiline":false,"display_order":0,"pattern":"https://.*","example":"https://github.com/foo"}
              ]}]'::jsonb,
            false,
            false
        )
    $$,
    $$ VALUES (1, 1, 0, 0, 2, 1, 0, 2, false) $$,
    'sync_assignments should apply assignment and field changes'
);

SELECT set_eq(
    'SELECT slug FROM api.assignments ORDER BY slug',
    ARRAY['exam-1', 'js-koans', 'new-admin-assignment', 'project-update-1', 'team-selection'],
    'sync_assignments should preserve unrelated assignments when delete_missing is false'
);

SELECT set_eq(
    'SELECT assignment_slug || ''/'' || slug FROM api.assignment_fields WHERE assignment_slug IN (''exam-1'', ''new-admin-assignment'') ORDER BY assignment_slug, slug',
    ARRAY['exam-1/new-field', 'exam-1/url', 'new-admin-assignment/repo-url'],
    'sync_assignments should replace fields for assignments included in the payload'
);

SELECT results_eq(
    $$
        SELECT
            inserted_count,
            updated_count,
            unchanged_count,
            deleted_count,
            field_inserted_count,
            field_updated_count,
            field_unchanged_count,
            field_deleted_count,
            dry_run
        FROM api.sync_assignments(
            '[{"slug":"exam-1","title":"Updated Exam","points_possible":55,"is_draft":false,"is_markdown":false,"is_team":false,"body":"updated body","closed_at":"3018-12-27T14:55:50Z","fields":[
                {"slug":"url","label":"Updated repo","help":"Updated help","placeholder":"https://github.com/...","is_url":true,"is_multiline":false,"display_order":1,"pattern":"https://.*","example":"https://github.com/foo"},
                {"slug":"new-field","label":"New Field","help":"New help","placeholder":"value","is_url":false,"is_multiline":false,"display_order":2,"pattern":".*","example":"value"}
              ]},
              {"slug":"new-admin-assignment","title":"New Admin Assignment","points_possible":10,"is_draft":true,"is_markdown":false,"is_team":false,"body":"new body","closed_at":"3018-12-28T14:55:50Z","fields":[
                {"slug":"repo-url","label":"Repo URL","help":"Repo help","placeholder":"https://github.com/...","is_url":true,"is_multiline":false,"display_order":0,"pattern":"https://.*","example":"https://github.com/foo"}
              ]}]'::jsonb,
            false,
            false
        )
    $$,
    $$ VALUES (0, 0, 2, 0, 0, 0, 3, 0, false) $$,
    'rerunning sync_assignments should report unchanged rows rather than duplicate updates'
);

SELECT results_eq(
    $$
        SELECT
            inserted_count,
            updated_count,
            unchanged_count,
            deleted_count,
            field_inserted_count,
            field_updated_count,
            field_unchanged_count,
            field_deleted_count,
            dry_run
        FROM api.sync_assignments(
            '[{"slug":"team-selection","title":"Select your team","points_possible":50,"is_draft":false,"is_markdown":false,"is_team":false,"body":"Lorem body lorem","closed_at":"3018-12-27T14:55:50Z","fields":[
                {"slug":"secret","label":"Your team secret","help":"Choose something unique","placeholder":"FOO-BAR-BAZ","is_url":false,"is_multiline":false,"display_order":0,"pattern":".*","example":"your-secret-here"}
              ]},
              {"slug":"project-update-1","title":"First Project update","points_possible":75,"is_draft":false,"is_markdown":false,"is_team":true,"body":"big lorem here","closed_at":"3018-12-27T14:55:50Z","fields":[
                {"slug":"repo-url","label":"team-repo","help":"Should be on class github","placeholder":"http://github.com","is_url":true,"is_multiline":false,"display_order":0,"pattern":".*","example":"http://bar.com/baz/?foo"},
                {"slug":"update-url","label":"sprint-report","help":"A google doc","placeholder":"http://docs.google.com","is_url":true,"is_multiline":false,"display_order":0,"pattern":".*","example":"https://www.yale.edu"}
              ]},
              {"slug":"exam-1","title":"Updated Exam","points_possible":55,"is_draft":false,"is_markdown":false,"is_team":false,"body":"updated body","closed_at":"3018-12-27T14:55:50Z","fields":[
                {"slug":"url","label":"Updated repo","help":"Updated help","placeholder":"https://github.com/...","is_url":true,"is_multiline":false,"display_order":1,"pattern":"https://.*","example":"https://github.com/foo"},
                {"slug":"new-field","label":"New Field","help":"New help","placeholder":"value","is_url":false,"is_multiline":false,"display_order":2,"pattern":".*","example":"value"}
              ]},
              {"slug":"new-admin-assignment","title":"New Admin Assignment","points_possible":10,"is_draft":true,"is_markdown":false,"is_team":false,"body":"new body","closed_at":"3018-12-28T14:55:50Z","fields":[
                {"slug":"repo-url","label":"Repo URL","help":"Repo help","placeholder":"https://github.com/...","is_url":true,"is_multiline":false,"display_order":0,"pattern":"https://.*","example":"https://github.com/foo"}
              ]}]'::jsonb,
            true,
            false
        )
    $$,
    $$ VALUES (0, 0, 4, 1, 0, 0, 6, 1, false) $$,
    'sync_assignments should delete missing unreferenced assignments and fields when delete_missing is true'
);

SELECT set_eq(
    'SELECT slug FROM api.assignments ORDER BY slug',
    ARRAY['exam-1', 'new-admin-assignment', 'project-update-1', 'team-selection'],
    'sync_assignments delete_missing should preserve referenced and input assignments'
);

SELECT throws_like(
    $$
        SELECT * FROM api.sync_assignments(
            '[{"slug":"project-update-1","title":"Project Update","points_possible":75,"is_draft":false,"is_markdown":false,"is_team":true,"body":"project body","closed_at":"3018-12-27T14:55:50Z","fields":[]}]'::jsonb,
            true,
            false
        )
    $$,
    '%violates foreign key constraint%',
    'sync_assignments should fail atomically when delete_missing would remove referenced assignment data'
);

SELECT set_eq(
    'SELECT slug FROM api.assignments ORDER BY slug',
    ARRAY['exam-1', 'new-admin-assignment', 'project-update-1', 'team-selection'],
    'failed sync_assignments should leave assignments unchanged'
);

SELECT set_eq(
    'SELECT assignment_slug || ''/'' || slug FROM api.assignment_fields WHERE assignment_slug IN (''exam-1'', ''new-admin-assignment'') ORDER BY assignment_slug, slug',
    ARRAY['exam-1/new-field', 'exam-1/url', 'new-admin-assignment/repo-url'],
    'failed sync_assignments should leave assignment fields unchanged'
);

select * from finish();
rollback;
