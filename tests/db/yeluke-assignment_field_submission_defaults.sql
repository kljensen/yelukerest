begin;
select plan(1);

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


select * from finish();
rollback;

