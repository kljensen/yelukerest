-- Tests for api.upsert_user_secrets and api.upsert_team_secrets (issue #303).
--
-- These rows are generated database passwords, so the assertion this file
-- exists for is that a body never comes back out: not in a success response,
-- not in an error message, not in a DETAIL, not in a HINT. Everything else here
-- is in service of that -- the pre-checks only keep the body out of PostgreSQL's
-- own error text if every constraint that would print it is caught first.

select plan(47);

--
-- Who may call them
--

SELECT function_privs_are(
    'api', 'upsert_user_secrets', ARRAY['jsonb', 'boolean'],
    'anonymous', ARRAY[]::text[],
    'anonymous should not be able to execute api.upsert_user_secrets'
);

SELECT function_privs_are(
    'api', 'upsert_user_secrets', ARRAY['jsonb', 'boolean'],
    'student', ARRAY[]::text[],
    'students should not be able to execute api.upsert_user_secrets'
);

SELECT function_privs_are(
    'api', 'upsert_user_secrets', ARRAY['jsonb', 'boolean'],
    'ta', ARRAY[]::text[],
    'tas should not be able to execute api.upsert_user_secrets'
);

SELECT function_privs_are(
    'api', 'upsert_user_secrets', ARRAY['jsonb', 'boolean'],
    'faculty', ARRAY['EXECUTE'],
    'faculty should be able to execute api.upsert_user_secrets'
);

SELECT function_privs_are(
    'api', 'upsert_team_secrets', ARRAY['jsonb', 'boolean'],
    'student', ARRAY[]::text[],
    'students should not be able to execute api.upsert_team_secrets'
);

SELECT function_privs_are(
    'api', 'upsert_team_secrets', ARRAY['jsonb', 'boolean'],
    'faculty', ARRAY['EXECUTE'],
    'faculty should be able to execute api.upsert_team_secrets'
);

SELECT function_privs_are(
    'data', 'check_user_secret_batch', ARRAY['jsonb', 'text', 'text'],
    'student', ARRAY[]::text[],
    'students should not be able to validate a secret payload directly'
);

SELECT ok(
    NOT has_function_privilege('student', 'data.user_secret_input_bounds()', 'EXECUTE'),
    'students should not be able to read the user_secret input bounds'
);

--
-- The return shape. A body column added here would leak every secret the call
-- touched, so the signature is pinned rather than sampled.
--

SELECT is(
    pg_get_function_result('api.upsert_user_secrets(jsonb,boolean)'::regprocedure),
    'TABLE(inserted_count integer, updated_count integer, unchanged_count integer, dry_run boolean)',
    'api.upsert_user_secrets should return counts and nothing else'
);

SELECT is(
    pg_get_function_result('api.upsert_team_secrets(jsonb,boolean)'::regprocedure),
    'TABLE(inserted_count integer, updated_count integer, unchanged_count integer, dry_run boolean)',
    'api.upsert_team_secrets should return counts and nothing else'
);

--
-- The whole reason these are RPCs rather than POSTs to a view faculty already
-- hold CRUD on: both arbiters are partial indexes, and PostgREST's on_conflict
-- cannot carry an index predicate. If either predicate is dropped or reshaped,
-- the ON CONFLICT clauses inside the functions stop inferring it.
--

SELECT results_eq(
    $$
        SELECT indexdef
        FROM pg_indexes
        WHERE schemaname = 'data'
        AND tablename = 'user_secret'
        AND indexdef LIKE 'CREATE UNIQUE INDEX%'
        AND indexname <> 'user_secret_pkey'
        ORDER BY indexdef
    $$,
    $$ VALUES
        ('CREATE UNIQUE INDEX secret_unique_slug_team ON data.user_secret USING btree (team_nickname, slug) WHERE (user_id IS NULL)'::text),
        ('CREATE UNIQUE INDEX secret_unique_slug_user ON data.user_secret USING btree (user_id, slug) WHERE (team_nickname IS NULL)'::text)
    $$,
    'the user_secret arbiters should still be the two partial unique indexes the upserts infer'
);

-- Pins the constraint shapes data.user_secret_input_bounds reads. Unlike
-- data.grade_exception_credit_bounds, a NULL here is not a soft failure that
-- lets the write become the only check -- it is the leak, because the write is
-- what prints the body. The functions refuse to run in that state, so a reshape
-- here breaks secret distribution outright rather than quietly.
SELECT results_eq(
    $$ SELECT * FROM data.user_secret_input_bounds() $$,
    $$ VALUES (8192, '^[a-z0-9][a-z0-9_-]+[a-z0-9]$'::text, 100, 50) $$,
    'the user_secret input bounds should be readable from the constraints themselves'
);

--
-- The danger is real, not theoretical. This is the write path the pre-checks
-- exist to keep a payload away from: PostgreSQL renders a CHECK violation with
-- the whole failing row attached, and PostgREST forwards DETAIL to the client.
-- Run as the test superuser, which holds SELECT on data.user_secret, because
-- that is when PostgreSQL emits the row description.
--

CREATE FUNCTION pg_temp.error_text(statement text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    message text;
    detail text;
    hint text;
BEGIN
    EXECUTE statement;
    RETURN '<no error raised>';
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
        message = MESSAGE_TEXT,
        detail = PG_EXCEPTION_DETAIL,
        hint = PG_EXCEPTION_HINT;
    RETURN message || ' || ' || COALESCE(detail, '') || ' || ' || COALESCE(hint, '');
END $$;

SELECT ok(
    pg_temp.error_text($$
        INSERT INTO data.user_secret (user_id, slug, body)
        VALUES (1, 'BAD SLUG', 'SENTINEL-PASSWORD-8f3a1c')
    $$) LIKE '%SENTINEL-PASSWORD-8f3a1c%',
    'a raw CHECK violation does print the secret body, which is what the pre-checks exist to prevent'
);

SELECT ok(
    pg_temp.error_text($$
        INSERT INTO data.user_secret (user_id, slug, body)
        VALUES (1, NULL, 'SENTINEL-PASSWORD-8f3a1c')
    $$) LIKE '%SENTINEL-PASSWORD-8f3a1c%',
    'a raw NOT NULL violation does print the secret body too'
);

--
-- Nothing the RPCs raise may contain a body. Every rejection the functions can
-- produce is probed at once, as the superuser: faculty lack SELECT on
-- data.user_secret, so PostgreSQL would suppress the row description for them
-- whether or not the pre-checks did their job. Probing under the role that
-- would see it is what makes this assertion mean something.
--
-- request.user_role() is set to faculty so the row-level security WITH CHECK is
-- satisfied and a probe fails for the reason it is testing.
--

set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';

CREATE TEMP VIEW leak_probes AS
    SELECT * FROM (VALUES
        ('not an array',
         $$ SELECT * FROM api.upsert_user_secrets('{"netid":"abc123","body":"SENTINEL-PASSWORD-8f3a1c"}'::jsonb, true) $$),
        ('an element that is not an object',
         $$ SELECT * FROM api.upsert_user_secrets('["SENTINEL-PASSWORD-8f3a1c"]'::jsonb, true) $$),
        ('an empty list',
         $$ SELECT * FROM api.upsert_user_secrets('[]'::jsonb, true) $$),
        ('a missing netid',
         $$ SELECT * FROM api.upsert_user_secrets('[{"slug":"ok-slug","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb, true) $$),
        ('a missing slug',
         $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb, true) $$),
        ('a malformed slug',
         $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"BAD SLUG","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb, true) $$),
        ('an over-long slug',
         $$ SELECT * FROM api.upsert_user_secrets(('[{"netid":"abc123","slug":"' || repeat('a', 100) || '","body":"SENTINEL-PASSWORD-8f3a1c"}]')::jsonb, true) $$),
        ('a missing body',
         $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"ok-slug"}]'::jsonb, true) $$),
        ('a null body',
         $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"ok-slug","body":null}]'::jsonb, true) $$),
        ('a non-string body',
         $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"ok-slug","body":{"was":"SENTINEL-PASSWORD-8f3a1c"}}]'::jsonb, true) $$),
        ('an oversized body',
         $$ SELECT * FROM api.upsert_user_secrets(('[{"netid":"abc123","slug":"ok-slug","body":"' || repeat('SENTINEL-PASSWORD-8f3a1c', 400) || '"}]')::jsonb, true) $$),
        ('a non-boolean is_user_visible',
         $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"ok-slug","body":"SENTINEL-PASSWORD-8f3a1c","is_user_visible":null}]'::jsonb, true) $$),
        ('an unknown netid',
         $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"nobody","slug":"ok-slug","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb, true) $$),
        ('two rows resolving to one secret',
         $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"ok-slug","body":"SENTINEL-PASSWORD-8f3a1c"},{"netid":"ABC123","slug":"ok-slug","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb, true) $$),
        ('an unknown team nickname',
         $$ SELECT * FROM api.upsert_team_secrets('[{"team_nickname":"no-team","slug":"ok-slug","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb, true) $$),
        ('an over-long team nickname',
         $$ SELECT * FROM api.upsert_team_secrets(('[{"team_nickname":"' || repeat('z', 50) || '","slug":"ok-slug","body":"SENTINEL-PASSWORD-8f3a1c"}]')::jsonb, true) $$),
        ('a malformed slug on the team variant',
         $$ SELECT * FROM api.upsert_team_secrets('[{"team_nickname":"bright-fog","slug":"BAD SLUG","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb, true) $$),
        ('a real write, not a dry run',
         $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"BAD SLUG","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb, false) $$)
    ) AS probe(label, statement);

-- Guards the assertion below against passing vacuously: if a probe stopped
-- raising, its error text would trivially contain no secret.
SELECT is(
    (
        SELECT coalesce(string_agg(probe.label, ', ' ORDER BY probe.label), '')
        FROM leak_probes AS probe
        WHERE pg_temp.error_text(probe.statement) = '<no error raised>'
    ),
    '',
    'every leak probe should still be rejected, so the leak assertion cannot pass vacuously'
);

SELECT is(
    (
        SELECT coalesce(string_agg(probe.label, ', ' ORDER BY probe.label), '')
        FROM leak_probes AS probe
        WHERE pg_temp.error_text(probe.statement) LIKE '%SENTINEL-PASSWORD-8f3a1c%'
    ),
    '',
    'no error raised by the secret upserts should contain a secret body'
);

--
-- Nor may a success response. The whole row is checked, not a named column, so
-- a column added later is covered too.
--

SELECT is(
    (
        SELECT (upserted)::text
        FROM api.upsert_user_secrets(
            '[{"netid":"abc123","slug":"probe-secret","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb,
            true
        ) AS upserted
    ),
    '(1,0,0,t)',
    'a dry run should answer with counts alone'
);

SELECT is(
    (
        SELECT (upserted)::text
        FROM api.upsert_user_secrets(
            '[{"netid":"abc123","slug":"probe-secret","body":"SENTINEL-PASSWORD-8f3a1c"}]'::jsonb,
            false
        ) AS upserted
    ),
    '(1,0,0,f)',
    'a real write should answer with counts alone'
);

DELETE FROM api.user_secrets WHERE slug = 'probe-secret';

--
-- Students are shut out at the endpoint, before row-level security is reached.
--

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT throws_like(
    $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"ok-slug","body":"x"}]'::jsonb) $$,
    '%permission denied%',
    'students should not be able to hand themselves a secret'
);

SELECT throws_like(
    $$ SELECT * FROM api.upsert_team_secrets('[{"team_nickname":"bright-fog","slug":"ok-slug","body":"x"}]'::jsonb) $$,
    '%permission denied%',
    'students should not be able to hand their team a secret'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
set request.jwt.claim.user_id = '3';

--
-- Argument guards, by message. The probes above proved these carry no body;
-- these prove they name the row a person has to go and fix.
--

SELECT throws_like(
    $$ SELECT * FROM api.upsert_user_secrets('[]'::jsonb) $$,
    '%upsert_user_secrets refuses to import an empty secret list%',
    'upsert_user_secrets should refuse an empty list'
);

SELECT throws_like(
    $$ SELECT * FROM api.upsert_user_secrets('[{"slug":"ok-slug","body":"x"}]'::jsonb) $$,
    '%requires netid and slug on every secret, missing at position: 1%',
    'upsert_user_secrets should name the position of a row with no netid'
);

SELECT throws_like(
    $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"BAD SLUG","body":"x"}]'::jsonb) $$,
    '%requires a slug matching%: abc123/BAD SLUG%',
    'upsert_user_secrets should name the netid and slug of a malformed slug'
);

SELECT throws_like(
    $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"ok-slug"}]'::jsonb) $$,
    '%requires a string body on every secret: abc123/ok-slug%',
    'upsert_user_secrets should refuse a secret with no body'
);

SELECT throws_like(
    $$ SELECT * FROM api.upsert_user_secrets(('[{"netid":"abc123","slug":"ok-slug","body":"' || repeat('x', 8193) || '"}]')::jsonb) $$,
    '%requires a body of at most 8192 bytes: abc123/ok-slug%',
    'upsert_user_secrets should read the body limit off the constraint and name the offending key'
);

SELECT throws_like(
    $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"nobody","slug":"ok-slug","body":"x"}]'::jsonb) $$,
    '%does not know netid: nobody%',
    'upsert_user_secrets should name an unknown netid rather than dropping the row'
);

SELECT throws_like(
    $$ SELECT * FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"ok-slug","body":"x"},{"netid":"ABC123","slug":"ok-slug","body":"y"}]'::jsonb) $$,
    '%received duplicate netid/slug key: abc123/ok-slug%',
    'upsert_user_secrets should catch two rows that resolve to one secret, even across netid case'
);

SELECT throws_like(
    $$ SELECT * FROM api.upsert_team_secrets('[{"team_nickname":"no-team","slug":"ok-slug","body":"x"}]'::jsonb) $$,
    '%does not know team nickname: no-team%',
    'upsert_team_secrets should name an unknown team nickname'
);

--
-- Counting and re-runnability. The sample data holds abc123/foo = bar1,
-- bde456/foo = bar2, and bright-fog/baz = wuz.
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, dry_run
        FROM api.upsert_user_secrets('[
            {"netid":"abc123","slug":"foo","body":"bar1"},
            {"netid":"bde456","slug":"foo","body":"moved"},
            {"netid":"klj39","slug":"rds-password","body":"fresh"}]'::jsonb, true)
    $$,
    $$ VALUES (1, 1, 1, true) $$,
    'a dry run should sort the payload into new, changed and unchanged'
);

SELECT is(
    (SELECT count(*)::int FROM api.user_secrets),
    3,
    'a dry run should write nothing'
);

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count, dry_run
        FROM api.upsert_user_secrets('[
            {"netid":"abc123","slug":"foo","body":"bar1"},
            {"netid":"bde456","slug":"foo","body":"moved"},
            {"netid":"klj39","slug":"rds-password","body":"fresh"}]'::jsonb)
    $$,
    $$ VALUES (1, 1, 1, false) $$,
    'the real write should report what the dry run predicted'
);

SELECT results_eq(
    $$
        SELECT user_id, team_nickname, slug, body, is_user_visible
        FROM api.user_secrets
        WHERE slug = 'rds-password'
    $$,
    $$ VALUES (3, NULL::text, 'rds-password'::text, 'fresh'::text, true) $$,
    'a user secret should carry a user id, no team, and the default visibility'
);

SELECT is(
    (SELECT body FROM api.user_secrets WHERE user_id = 2 AND slug = 'foo'),
    'moved',
    'a changed secret should hold the new body'
);

--
-- Re-running must not restamp a secret it did not change. `updated_at` is a
-- record of when a password was last rotated, and a nightly re-run of the same
-- payload would otherwise make every secret look freshly issued. The DO UPDATE
-- carries a WHERE for exactly this.
--

CREATE TEMP TABLE stamp_before_rerun AS
    SELECT slug, updated_at FROM api.user_secrets WHERE slug = 'rds-password';

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.upsert_user_secrets('[
            {"netid":"abc123","slug":"foo","body":"bar1"},
            {"netid":"bde456","slug":"foo","body":"moved"},
            {"netid":"klj39","slug":"rds-password","body":"fresh"}]'::jsonb)
    $$,
    $$ VALUES (0, 0, 3) $$,
    'a second run of the same payload should write nothing'
);

SELECT results_eq(
    $$ SELECT updated_at FROM api.user_secrets WHERE slug = 'rds-password' $$,
    $$ SELECT updated_at FROM stamp_before_rerun $$,
    'an unchanged secret should keep the updated_at it already had'
);

--
-- is_user_visible. Absent means "leave it alone", so rotating a password does
-- not un-hide a secret faculty deliberately hid.
--

SELECT is(
    (
        SELECT inserted_count
        FROM api.upsert_user_secrets(
            '[{"netid":"jlb325","slug":"exam-link","body":"first","is_user_visible":false}]'::jsonb
        )
    ),
    1,
    'a secret may be created hidden'
);

SELECT is(
    (SELECT is_user_visible FROM api.user_secrets WHERE slug = 'exam-link'),
    false,
    'an explicit false should be written'
);

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.upsert_user_secrets('[{"netid":"jlb325","slug":"exam-link","body":"second"}]'::jsonb)
    $$,
    $$ VALUES (0, 1, 0) $$,
    'rotating the body of a hidden secret should be one update'
);

SELECT is(
    (SELECT is_user_visible FROM api.user_secrets WHERE slug = 'exam-link'),
    false,
    'an absent is_user_visible should leave a hidden secret hidden'
);

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.upsert_user_secrets('[{"netid":"jlb325","slug":"exam-link","body":"second","is_user_visible":true}]'::jsonb)
    $$,
    $$ VALUES (0, 1, 0) $$,
    'changing only the visibility should still be an update'
);

--
-- The team variant writes through the other partial index.
--

SELECT results_eq(
    $$
        SELECT inserted_count, updated_count, unchanged_count
        FROM api.upsert_team_secrets('[
            {"team_nickname":"bright-fog","slug":"baz","body":"wuz"},
            {"team_nickname":"hazy-mountain","slug":"baz","body":"other"}]'::jsonb)
    $$,
    $$ VALUES (1, 0, 1) $$,
    'a team payload should sort into new and unchanged the same way'
);

SELECT results_eq(
    $$
        SELECT user_id, team_nickname, slug, body
        FROM api.user_secrets
        WHERE team_nickname = 'hazy-mountain'
    $$,
    $$ VALUES (NULL::int, 'hazy-mountain'::text, 'baz'::text, 'other'::text) $$,
    'a team secret should carry a team nickname and no user id'
);

-- The two indexes are separate rules, so one slug can exist on both sides at
-- once without either upsert seeing the other row.
SELECT is(
    (
        SELECT inserted_count
        FROM api.upsert_user_secrets('[{"netid":"abc123","slug":"baz","body":"personal"}]'::jsonb)
    ),
    1,
    'a user secret should not collide with a team secret of the same slug'
);

SELECT is(
    (SELECT count(*)::int FROM api.user_secrets WHERE slug = 'baz'),
    3,
    'the team and user secrets sharing a slug should all survive'
);

--
-- End to end: a student reads the secret the RPC wrote for them, and only that
-- one. Row-level security is what makes distribution safe once the write lands.
--

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT is(
    (SELECT body FROM api.user_secrets WHERE slug = 'baz' AND user_id = 1),
    'personal',
    'a student should be able to read the personal secret written for them'
);

SELECT is(
    (SELECT count(*)::int FROM api.user_secrets WHERE slug = 'rds-password'),
    0,
    'a student should not see another user secret written by the same call'
);

-- exam-link was created hidden, stayed hidden through a body rotation that did
-- not mention visibility, and was un-hidden by an explicit flag. Row-level
-- security follows the column, so this is the round trip end to end. The
-- opposite direction -- a hidden secret staying invisible to its owner -- is
-- covered in tests/db/yeluke-user_secrets.sql.
set request.jwt.claim.user_id = '4';

SELECT is(
    (SELECT count(*)::int FROM api.user_secrets WHERE slug = 'exam-link'),
    1,
    'a secret un-hidden through the RPC should become readable by the user it belongs to'
);

select * from finish();
