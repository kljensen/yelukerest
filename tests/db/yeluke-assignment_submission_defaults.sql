SELECT plan(1)
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SELECT set_eq('
    with 
    updated_rows as (
      INSERT INTO api.assignment_submissions (assignment_slug, user_id)
      VALUES (''team-selection'', 4)
      RETURNING submitter_user_id
    )
    select submitter_user_id as total from updated_rows
  ', ARRAY[4], 'submitter_user_id is autopopulated from the assignment_submission when not available')
; SELECT *
FROM finish()
