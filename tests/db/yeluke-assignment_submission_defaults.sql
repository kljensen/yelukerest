begin;
select plan(1);

set local role faculty;
set request.jwt.claim.role = 'faculty';


select set_eq (
  $$
    with 
    updated_rows as (
      INSERT INTO api.assignment_submissions (assignment_slug, user_id)
      VALUES ('team-selection', 4)
      RETURNING submitter_user_id
    )
    select submitter_user_id as total from updated_rows
  $$,
  ARRAY[4],
  'submitter_user_id is autopopulated from the assignment_submission when not available'
);


select * from finish();
rollback;

