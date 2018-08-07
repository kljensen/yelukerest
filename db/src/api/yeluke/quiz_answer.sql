create or replace view quiz_answers as
    select * from data.quiz_answer;


-- It is important to set the correct owner so the RLS policy kicks in.
alter view quiz_answers owner to api;

