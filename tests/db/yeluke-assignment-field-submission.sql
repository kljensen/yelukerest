begin;
select plan(22);

SELECT view_owner_is(
    'api', 'assignment_field_submissions', 'api',
    'api.assignment_field_submissions view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignment_field_submissions', 'student', ARRAY['SELECT', 'INSERT', 'UPDATE'],
    'student should only be granted SELECT, INSERT on view "api.assignment_field_submissions"'
);

SELECT table_privs_are(
    'api', 'assignment_field_submissions', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.assignment_field_submissions"'
);

SELECT table_privs_are(
    'data', 'assignment_submission', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.assignment_submission"'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT set_eq(
    'SELECT assignment_field_slug FROM api.assignment_field_submissions ORDER BY (assignment_field_slug)',
    ARRAY['repo-url', 'secret', 'secret', 'secret', 'update-url'],
    'faculty should be able to see all assignment field submissions'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT assignment_field_slug FROM api.assignment_field_submissions ORDER BY (assignment_field_slug)',
    ARRAY['repo-url', 'secret', 'update-url'],
    'students shoud only be able to see assignment field submissions that are their own or team submissions for their team (user 1)'
);

set request.jwt.claim.user_id = '2';

SELECT set_eq(
    'SELECT assignment_field_slug FROM api.assignment_field_submissions ORDER BY (assignment_field_slug)',
    ARRAY['secret'],
    'students shoud only be able to see assignment field submissions that are their own or team submissions for their team (user 2)'
);

PREPARE doinsert AS INSERT INTO api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,assignment_slug,body,submitter_user_id) VALUES($1, $2, $3, $4, $5);
set local role faculty;
set request.jwt.claim.role = 'faculty';
INSERT INTO api.assignment_submissions (id,assignment_slug, user_id, submitter_user_id) VALUES (11,'team-selection', 4, 4);
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '2';

SELECT throws_like(
    'EXECUTE doinsert(11, ''secret'', ''team-selection'', ''mysecret'', 4)', 
    '%violates row-level security policy%',
    'students should not be able to create an assignment field submission for a different user'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.assignments SET is_draft = TRUE WHERE (slug = 'team-selection');
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';

SELECT throws_like(
    'EXECUTE doinsert(11, ''secret'', ''team-selection'', ''mysecret'', 4)', 
    '%violates row-level security policy%',
    'students should not be able to create assignment field submissions if assignment is draft'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.assignments SET is_draft = FALSE, closed_at = current_timestamp - '1 hour'::INTERVAL WHERE slug='team-selection';
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';
SELECT throws_like(
    'EXECUTE doinsert(11, ''secret'', ''team-selection'', ''mysecret'', 4)', 
    '%violates row-level security policy%',
    'students should not be able to create assignment field submissions if assignment is closed'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.assignments SET closed_at = current_timestamp + '1 hour'::INTERVAL WHERE slug='team-selection';
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';


SELECT lives_ok(
    'INSERT INTO api.assignment_field_submissions (assignment_submission_id,assignment_field_slug, body) VALUES (11, ''secret'', ''mysecret'')',
    'students can create assignment field submissions and defaults get set'
);

SELECT results_eq(
    'SELECT request.user_role()',
    ARRAY['student'],
    'role is currently student'
);

SELECT lives_ok(
    'UPDATE api.assignment_field_submissions SET body=''woot'' WHERE assignment_submission_id=11 AND assignment_field_slug=''secret''', 
    'students can update their own assignment field submissions'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.assignments SET is_draft = TRUE WHERE slug='team-selection';
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';
SELECT throws_like(
    'UPDATE api.assignment_field_submissions SET body=''foooo'' WHERE assignment_submission_id=11 AND assignment_field_slug=''secret''', 
    '%violates row-level security policy%',
    'students cannot update a assignment field submission if the assignment is in draft'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';
UPDATE api.assignments SET is_draft = FALSE WHERE slug='team-selection';
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';

SELECT throws_like(
    'DELETE FROM api.assignment_field_submissions WHERE assignment_submission_id=11 AND assignment_field_slug=''secret''', 
    '%denied%',
    'students cannot delete their own assignment field submissions'
);


-- now, test for team crud...let's delete some of the sample data
-- and recreate it as students
set local role faculty;
set request.jwt.claim.role = 'faculty';
DELETE FROM api.assignment_field_submissions WHERE assignment_submission_id = 4 AND assignment_field_slug = 'repo-url';
DELETE FROM api.assignment_field_submissions WHERE assignment_submission_id = 4 AND assignment_field_slug = 'update-url';
UPDATE api.assignments SET closed_at = current_timestamp + '1 hour'::INTERVAL WHERE slug='team-selection';
set local role student;
set request.jwt.claim.role = 'student';

set request.jwt.claim.user_id = '3';

SELECT lives_ok(
    'EXECUTE doinsert(4, ''update-url'', ''project-update-1'', ''http://docs.google.com/fakedoc'', 3)', 
    'students can create assignment field submissions for their team'
);

set request.jwt.claim.user_id = '1';

SELECT lives_ok(
    'INSERT INTO api.assignment_field_submissions (assignment_slug, assignment_field_slug, body) VALUES (''project-update-1'', ''repo-url'', ''http://github.com/kljensen/fakerepo'')',
    'students can create an assignment field submissions for their team (only assignment_field_slug provided)'
);

select set_eq (
  $$
    with 
    updated_rows as (
      UPDATE api.assignment_field_submissions SET body='FOO' WHERE assignment_field_slug='repo-url' AND assignment_slug='project-update-1'
      RETURNING assignment_field_slug
    )
    select count(assignment_field_slug) as total from updated_rows
  $$,
  $$
    values(1)
  $$,
    'students can update an assignment field submission for their team (only assignment_field_slug provided)'
);

select set_eq (
  $$
    with 
    updated_rows as (
      UPDATE api.assignment_field_submissions SET body='FOOBAR' WHERE assignment_field_slug='update-url'
      RETURNING assignment_field_slug
    )
    select count(assignment_field_slug) as total from updated_rows
  $$,
  $$
    values(1)
  $$,
    'students can update an assignment field submissions for their team even when not the original submitter (only assignment_field_slug provided)'
);

select set_eq (
  $$
    with 
    updated_rows as (
      UPDATE api.assignment_field_submissions SET body='FOO' WHERE assignment_field_slug='secret'
      RETURNING assignment_field_slug
    )
    select count(assignment_field_slug) as total from updated_rows
  $$,
  $$
    values(1)
  $$,
    'students can update an assignment field submissions for themselves (only assignment_field_slug provided)'
);


set request.jwt.claim.user_id = '3';

SELECT lives_ok(
    'UPDATE api.assignment_field_submissions SET body=''http://woot'', submitter_user_id=3 WHERE assignment_submission_id=4 AND assignment_field_slug=''repo-url''', 
    'students can update assignment field submissions for their team, even if they did not create it'
);

set request.jwt.claim.user_id = '2';

select set_eq (
  $$
    with 
    updated_rows as (
      UPDATE api.assignment_field_submissions SET body='FOO' WHERE assignment_submission_id=4
      RETURNING assignment_field_slug
    )
    select count(assignment_field_slug) as total from updated_rows
  $$,
  $$
    values(0)
  $$,
    'students cannot update assignment field submissions for another team'
);

select * from finish();
rollback;

