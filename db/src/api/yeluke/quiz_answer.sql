create or replace view quiz_answers as
    select * from data.quiz_answer;


-- It is important to set the correct owner so the RLS policy kicks in.
-- The `quiz_answer` table does not have an RLS, but we're still
-- making `api` the owner of `quiz_answers`.
alter view quiz_answers owner to api;
