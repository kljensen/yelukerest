begin;
select plan(18);

SELECT view_owner_is(
    'api', 'user_secrets', 'api',
    'api.user_secrets view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'user_secrets', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.user_secrets"'
);

SELECT table_privs_are(
    'api', 'user_secrets', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.user_secrets"'
);

SELECT table_privs_are(
    'data', 'quiz_grade_exception', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz_grade_exception"'
);

SELECT col_not_null(
    'data', 'user_secret', 'is_user_visible',
    'data.user_secret.is_user_visible should be NOT NULL'
);

SELECT col_has_default(
    'data', 'user_secret', 'is_user_visible',
    'data.user_secret.is_user_visible should default to visible'
);

SELECT col_default_is(
    'data', 'user_secret', 'is_user_visible', 'true',
    'data.user_secret.is_user_visible should default to true'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.user_secrets',
    ARRAY[0],
    'students (and TAs) shoud not be able to see user_secrets for other students'
);

set request.jwt.claim.user_id = '2';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.user_secrets',
    ARRAY[1],
    'students shoud be able to see user_secrets of their own (count)'
);
SELECT set_eq(
    $$
        SELECT body FROM api.user_secrets WHERE slug='foo'
    $$,
    ARRAY['bar2'],
    'students shoud be able to see user_secrets of their own (select by slug)'
);

set request.jwt.claim.user_id = '1';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.user_secrets',
    ARRAY[2],
    'students shoud be able to see user_secrets of their team (count)'
);
SELECT set_eq(
    $$
        SELECT body FROM api.user_secrets WHERE slug='baz'
    $$,
    ARRAY['wuz'],
    'students shoud be able to see user_secrets of their team (select by slug)'
);

SELECT throws_like(
    $$
        INSERT INTO api.user_secrets (user_id, slug, body) VALUES (1, 'blah', 'blah') 
    $$,
    '%permission denied%',
    'students should NOT be able to create user_secrets'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
SELECT set_eq(
    'SELECT COUNT(*) FROM api.user_secrets',
    ARRAY[3],
    'faculty shoud be able to see all user_secrets (count)'
);

select set_eq (
  $$
    with 
    updated_rows as (
      INSERT INTO api.user_secrets (user_id, slug, body) VALUES (1, 'blah', 'blah') 
      RETURNING id
    )
    select count(id) as total from updated_rows
  $$,
  ARRAY[1],
  'faculty should be able to insert secrets'
);

INSERT INTO api.user_secrets (user_id, slug, body, is_user_visible)
VALUES (2, 'hidden', 'faculty-only', false);
INSERT INTO api.user_secrets (team_nickname, slug, body, is_user_visible)
VALUES ('bright-fog', 'hidden-team', 'faculty-only-team', false);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '2';
SELECT set_eq(
    $$
        SELECT COUNT(*) FROM api.user_secrets WHERE slug='hidden'
    $$,
    ARRAY[0],
    'students should not be able to see hidden user_secrets for themselves'
);

set request.jwt.claim.user_id = '1';
SELECT set_eq(
    $$
        SELECT COUNT(*) FROM api.user_secrets WHERE slug='hidden-team'
    $$,
    ARRAY[0],
    'students should not be able to see hidden user_secrets for their team'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

select set_eq (
  $$
    with 
    updated_rows as (
      UPDATE api.user_secrets SET body='blah' WHERE slug='foo' 
      RETURNING id
    )
    select count(id) as total from updated_rows
  $$,
  ARRAY[2],
  'faculty should be able to update secrets'
);


select * from finish();
rollback;
