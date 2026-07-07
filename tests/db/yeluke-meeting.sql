
BEGIN;

-- Plan the tests.
SELECT plan(24);

SELECT view_owner_is(
    'api', 'meetings', 'api',
    'api.meetings view should be owned by the api role'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_ok(
    'SELECT * FROM data.meeting',
    '42501',
    NULL,
    'anonymous user should not have access to the data schema'
);
SELECT throws_ok(
    'INSERT INTO api.meetings (slug, summary, description, begins_at, duration, is_draft, created_at, updated_at) VALUES (''intro'', ''my awesome summary'', ''description_1_'', ''2017-12-27 14:54:50+00'', ''00:00:03'', false, ''2017-12-27 14:54:50+00'', ''2017-12-27 21:11:02.845995+00'')',
    '42501',
    'permission denied for view meetings',
    'anonymous user should not be able to insert into the api.meetings view'
);

select set_eq(
    'select slug from api.meetings',
    array['intro', 'structuredquerylang', 'entrepreneurship-woot', 'server-side-apps'],
    'anonymous user can see all rows of the api.meetings view'
);

-- switch to a faculty application user
set local role faculty;
set request.jwt.claim.role = 'faculty';

-- Note that, here we are testing the `data` schema,
-- and NOT the `api` schema.
SELECT throws_ok(
    'SELECT * FROM data.meeting',
    '42501',
    NULL,
    'faculty should not have direct table access in the data schema'
);

select set_eq(
    'select slug from api.meetings',
    array['intro', 'structuredquerylang', 'entrepreneurship-woot', 'server-side-apps'],
    'faculty user can see all rows of the api.meetings view'
);

SELECT lives_ok(
    'INSERT INTO api.meetings (slug, title, summary, description, begins_at, duration, is_draft, created_at, updated_at) VALUES (''fakeclass'', ''fake class title'', ''my awesome summary'', ''description_1_'', ''2017-12-27 14:54:50+00'', ''00:00:03'', false, ''2017-12-27 14:54:50+00'', ''2017-12-27 21:11:02.845995+00'')',
    'faculty should be able to insert into the api.meetings view'
);

SELECT lives_ok(
    'UPDATE api.meetings SET description = ''foo'' WHERE slug=''fakeclass''',
    'faculty should be able to update meetings in the api.meetings view'
);

SELECT throws_like(
    'INSERT INTO api.meetings (slug, title, summary, description, begins_at, duration, is_draft, created_at, updated_at) VALUES (''fakeclass'', ''fake class title'', ''my awesome summary'', ''description_1_'', ''2017-12-27 14:54:50+00'', ''00:00:03'', false, ''2017-12-27 14:54:50+00'', ''2017-12-27 21:11:02.845995+00'')',
    '%duplicate key%',
    'meetings schema should reject duplicate slugs'
);

SELECT throws_like(
    'INSERT INTO api.meetings (slug, title, summary, description, begins_at, duration, is_draft, created_at, updated_at) VALUES (''abcdeX'', ''fake class title'', ''my awesome summary'', ''description_1_'', ''2017-12-27 14:54:50+00'', ''00:00:03'', false, ''2017-12-27 14:54:50+00'', ''2017-12-27 21:11:02.845995+00'')',
    '%violates check constraint "meeting_slug_check"%',
    'meetings slugs should be only [a-z0-9-]'
);
SELECT throws_like(
    'INSERT INTO api.meetings (slug, title, summary, description, begins_at, duration, is_draft, created_at, updated_at) VALUES (''abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789'', ''fake class title'', ''my awesome summary'', ''description_1_'', ''2017-12-27 14:54:50+00'', ''00:00:03'', false, ''2017-12-27 14:54:50+00'', ''2017-12-27 21:11:02.845995+00'')',
    '%violates check constraint "meeting_slug_check"%',
    'meetings slugs should be limited to 100 length'
);

SELECT table_privs_are(
    'api', 'meetings', 'faculty', ARRAY['SELECT', 'DELETE', 'INSERT', 'UPDATE'],
    'faculty should have CRUD privileges on the api.meetings view'
);

SELECT function_privs_are(
    'api', 'sync_meetings', ARRAY['jsonb'], 'anonymous', ARRAY[]::text[],
    'anonymous should not be able to execute api.sync_meetings'
);

SELECT function_privs_are(
    'api', 'sync_meetings', ARRAY['jsonb'], 'student', ARRAY[]::text[],
    'students should not be able to execute api.sync_meetings'
);

SELECT function_privs_are(
    'api', 'sync_meetings', ARRAY['jsonb'], 'faculty', ARRAY['EXECUTE'],
    'faculty should be able to execute api.sync_meetings'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT throws_like(
    $$ SELECT * FROM api.sync_meetings('[]'::jsonb) $$,
    '%permission denied%',
    'students should not be able to sync meetings'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT throws_like(
    $$ SELECT * FROM api.sync_meetings('[]'::jsonb) $$,
    '%refuses to sync an empty meeting list%',
    'sync_meetings should reject empty meeting lists'
);

SELECT throws_like(
    $$ SELECT * FROM api.sync_meetings('{"slug":"intro"}'::jsonb) $$,
    '%expects a JSON array%',
    'sync_meetings should reject non-array JSON'
);

SELECT throws_like(
    $$
        SELECT * FROM api.sync_meetings(
            '[{"slug":"same","title":"Same","summary":"","description":"first","begins_at":"2018-01-01T14:00:00Z","duration":"01:20:00","is_draft":false},
              {"slug":"same","title":"Same","summary":"","description":"second","begins_at":"2018-01-01T14:00:00Z","duration":"01:20:00","is_draft":false}]'::jsonb
        )
    $$,
    '%duplicate meeting slug%',
    'sync_meetings should reject duplicate input slugs'
);

SELECT throws_like(
    $$
        SELECT * FROM api.sync_meetings(
            '[{"slug":"intro","title":"Rollback Target","summary":"updated","description":"should not stick","begins_at":"2018-01-01T14:00:00Z","duration":"01:20:00","is_draft":false},
              {"slug":"structuredquerylang","title":"Databases and Structured Query Language","summary":"summary","description":"description","begins_at":"2018-01-02T14:00:00Z","duration":"01:20:00","is_draft":true},
              {"slug":"entrepreneurship-woot","title":"The Lean Start-up","summary":"summary","description":"description","begins_at":"2018-01-03T14:00:00Z","duration":"01:20:00","is_draft":false},
              {"slug":"BadSlug","title":"Invalid Slug","summary":"new","description":"new description","begins_at":"2018-01-02T14:00:00Z","duration":"01:20:00","is_draft":true}]'::jsonb
        )
    $$,
    '%meeting_slug_check%',
    'sync_meetings should roll back earlier deletes and updates when a later row fails'
);

SELECT set_eq(
    'SELECT slug FROM api.meetings ORDER BY slug',
    ARRAY['entrepreneurship-woot', 'fakeclass', 'intro', 'server-side-apps', 'structuredquerylang'],
    'failed sync_meetings should leave the meeting set unchanged'
);

SELECT is(
    (SELECT title FROM api.meetings WHERE slug = 'intro'),
    'Introduction to the class',
    'failed sync_meetings should leave updated rows unchanged'
);

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, deleted_count
        FROM api.sync_meetings(
            '[{"slug":"intro","title":"Updated Introduction","summary":"updated","description":"updated description","begins_at":"2018-01-01T14:00:00Z","duration":"01:20:00","is_draft":false},
              {"slug":"structuredquerylang","title":"Databases and Structured Query Language","summary":"summary","description":"description","begins_at":"2018-01-02T14:00:00Z","duration":"01:20:00","is_draft":true},
              {"slug":"entrepreneurship-woot","title":"The Lean Start-up","summary":"summary","description":"description","begins_at":"2018-01-03T14:00:00Z","duration":"01:20:00","is_draft":false},
              {"slug":"new-admin-meeting","title":"New Admin Meeting","summary":"new","description":"new description","begins_at":"2018-01-02T14:00:00Z","duration":"01:20:00","is_draft":true}]'::jsonb
        )
    $$,
    $$ VALUES (1, 3, 2) $$,
    'sync_meetings should report inserted, updated, and deleted counts'
);

SELECT set_eq(
    'SELECT slug FROM api.meetings ORDER BY slug',
    ARRAY['entrepreneurship-woot', 'intro', 'new-admin-meeting', 'structuredquerylang'],
    'sync_meetings should replace the meeting set'
);

-- Finish the tests and clean up.
SELECT * FROM finish();
ROLLBACK;
