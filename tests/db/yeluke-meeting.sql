
BEGIN;

-- Plan the tests.
SELECT plan(10);

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
    'INSERT INTO api.meetings (id, slug, summary, description, begins_at, duration, is_draft, created_at, updated_at) VALUES (20, ''intro'', ''my awesome summary'', ''description_1_'', ''2017-12-27 14:54:50+00'', ''00:00:03'', false, ''2017-12-27 14:54:50+00'', ''2017-12-27 21:11:02.845995+00'')',
    '42501',
    'permission denied for relation meetings',
    'anonymous user should not be able to insert into the api.meetings view'
);

select set_eq(
    'select id from api.meetings',
    array[ 1, 2, 3 ],
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
    'select id from api.meetings',
    array[ 1, 2, 3 ],
    'faculty user can see all rows of the api.meetings view'
);

SELECT lives_ok(
    'INSERT INTO api.meetings (id, slug, summary, description, begins_at, duration, is_draft, created_at, updated_at) VALUES (20, ''fakeclass'', ''my awesome summary'', ''description_1_'', ''2017-12-27 14:54:50+00'', ''00:00:03'', false, ''2017-12-27 14:54:50+00'', ''2017-12-27 21:11:02.845995+00'')',
    'faculty should be able to insert into the api.meetings view'
);

SELECT lives_ok(
    'UPDATE api.meetings SET description = ''foo'' WHERE id=20',
    'faculty should be able to update meetings in the api.meetings view'
);

SELECT throws_ok(
    'INSERT INTO api.meetings (id, slug, summary, description, begins_at, duration, is_draft, created_at, updated_at) VALUES (21, ''fakeclass'', ''my awesome summary'', ''description_1_'', ''2017-12-27 14:54:50+00'', ''00:00:03'', false, ''2017-12-27 14:54:50+00'', ''2017-12-27 21:11:02.845995+00'')',
    '23505',
    'duplicate key value violates unique constraint "meeting_slug_key"',
    'meetings schema should reject duplicate slugs'
);


SELECT table_privs_are(
    'api', 'meetings', 'faculty', ARRAY['SELECT', 'DELETE', 'INSERT', 'UPDATE'],
    'faculty should have CRUD privileges on the api.meetings view'
);

-- Finish the tests and clean up.
SELECT * FROM finish();
ROLLBACK;