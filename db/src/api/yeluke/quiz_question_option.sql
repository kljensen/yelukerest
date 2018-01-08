create or replace view quiz_question_options as
    select * from data.quiz_question_option;


-- It is important to set the correct owner so the RLS policy kicks in.
-- The `quiz_question_option` table does not have an RLS, but we're still
-- making `api` the owner of `quiz_question_options`.
alter view quiz_question_options owner to api;
