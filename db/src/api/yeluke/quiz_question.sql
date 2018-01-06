create or replace view quiz_questions as
    select * from data.quiz_question;
    -- Need to make this a join against quiz_question???

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `quiz_question` table does not have an RLS, but we're still
-- making `api` the owner of `quiz_questions`.
alter view quiz_questions owner to api;
