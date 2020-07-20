create or replace view quiz_questions as
    select
    *,
    (select count(id)>1 from data.quiz_question_option where is_correct=true and quiz_question_id=qq.id) as multiple_correct
    from data.quiz_question qq;


-- It is important to set the correct owner so the RLS policy kicks in.
alter view quiz_questions owner to api;
