create or replace view quiz_submissions as
    select * from data.quiz_submission;
    -- Need to make this a join against quiz_submission???

-- It is important to set the correct owner so the RLS policy kicks in.
alter view quiz_submissions owner to api;
