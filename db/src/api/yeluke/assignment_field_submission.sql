create or replace view assignment_field_submissions as
    select * from data.assignment_field_submission;

-- It is important to set the correct owner so the RLS policy kicks in.
alter view assignment_field_submissions owner to api;
