begin;
select plan(13);

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
