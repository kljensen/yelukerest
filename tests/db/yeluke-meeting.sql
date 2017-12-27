
BEGIN;

-- Plan the tests.
SELECT plan(3);

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
    'INSERT INTO api.meetings (id, slug, summary, description, begins_at, duration, is_draft, created_at, updated_at) VALUES (20, ''intro'', ''summary_2_2_2'', ''description_1_'', ''2017-12-27 14:54:50+00'', ''00:00:03'', false, ''2017-12-27 14:54:50+00'', ''2017-12-27 21:11:02.845995+00'')',
    '42501',
    'permission denied for relation meetings',
    'anonymous user should not be able to insert into the api.meetings view'
);

select set_eq(
    'select id from api.meetings',
    array[ 1, 2, 3 ],
    'anonymous user can see all rows of the api.meetings view'
);

-- Finish the tests and clean up.
SELECT * FROM finish();
ROLLBACK;