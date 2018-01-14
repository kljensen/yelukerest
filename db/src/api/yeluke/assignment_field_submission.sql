create or replace view assignment_field_submissions as
    select * from data.assignment_field_submission;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `assignment_field_submission` table does not have an RLS, but we're still
-- making `api` the owner of `assignment_field_submissions`.
alter view assignment_field_submissions owner to api;
