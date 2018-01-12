create or replace view assignment_submissions as
    select * from data.assignment_submission;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `assignment_submission` table does not have an RLS, but we're still
-- making `api` the owner of `assignment_submissions`.
alter view assignment_submissions owner to api;
