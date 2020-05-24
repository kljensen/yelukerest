begin;
select plan(4);

INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,pattern,example)
VALUES ('exam-1', 'pattern-field', 'gobblygook', 'find this online', 'e.g. foo', '.*foo.*', 'xfoobar');

INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,is_url,example)
VALUES ('exam-1', 'url-field', 'gobblygook', 'find this online', 'e.g. http://kljensen', true, 'https://foo.com');

SELECT throws_like(
    $$
        INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,pattern,example) VALUES ('exam-1', 'myfieldslug', 'gobblygook', 'find this online', 'e.g. kljensen', 'foo.*', 'bar')
    $$,
    '%violates check constraint%',
    'if a pattern is provided, an example must match it (negative case)'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';


INSERT INTO api.assignment_submissions (id,assignment_slug, user_id, submitter_user_id) VALUES (11,'team-selection', 4, 4);
select set_eq (
  $$
    with 
    updated_rows as (
      INSERT INTO
        api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,assignment_slug,body)
      VALUES (11, 'secret', 'team-selection', 'mysecret')
      RETURNING submitter_user_id
    )
    select submitter_user_id as total from updated_rows
  $$,
  ARRAY[4],
  'submitter_user_id is autopopulated from the assignment_submission when not available'
);

INSERT INTO api.assignment_submissions (id,assignment_slug, user_id, submitter_user_id) VALUES (6001,'exam-1', 4, 4);
select set_eq (
  $$
    with 
    updated_rows as (
      INSERT INTO
        api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,assignment_slug,body)
      VALUES (6001, 'pattern-field', 'exam-1', 'xfoobar')
      RETURNING assignment_field_pattern
    )
    select assignment_field_pattern from updated_rows
  $$,
  ARRAY['.*foo.*'],
  'pattern is autopopulated from the assignment when not available'
);

select set_eq (
  $$
    with 
    updated_rows as (
      INSERT INTO
        api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,assignment_slug,body)
      VALUES (6001, 'url-field', 'exam-1', 'https://bar.com')
      RETURNING assignment_field_is_url
    )
    select assignment_field_is_url from updated_rows
  $$,
  ARRAY[true],
  'is_url is autopopulated from the assignment when not available'
);


select * from finish();
rollback;

