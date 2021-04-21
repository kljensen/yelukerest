
BEGIN;

-- Plan the tests.
SELECT plan(12);

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
    'permission denied for schema data',
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
    'permission denied for schema data',
    'anonymous user should not have access to the data schema'
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

-- Finish the tests and clean up.
SELECT * FROM finish();
ROLLBACK;