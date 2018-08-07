create or replace view quizzes as
    select
        quiz.*,
        (
            quiz.is_draft = false and
            quiz.open_at < current_timestamp and
            current_timestamp < quiz.closed_at
        ) AS is_open
    from data.quiz;

-- It is important to set the correct owner so the RLS policy kicks in.
alter view quizzes owner to api;
