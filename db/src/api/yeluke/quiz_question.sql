create or replace view quiz_questions as
    select * from data.quiz_question;


-- It is important to set the correct owner so the RLS policy kicks in.
alter view quiz_questions owner to api;
