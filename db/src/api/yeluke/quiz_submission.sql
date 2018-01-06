create or replace view quiz_submissions as
    select * from data.quiz_submission;
    -- Need to make this a join against quiz_submission???

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `quiz_submission` table does not have an RLS, but we're still
-- making `api` the owner of `quiz_submissions`.
alter view quiz_submissions owner to api;
