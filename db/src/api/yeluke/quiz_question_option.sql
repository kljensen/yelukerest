create or replace view quiz_question_options as
    select * from data.quiz_question_option;


-- It is important to set the correct owner so the RLS policy kicks in.
alter view quiz_question_options owner to api;
