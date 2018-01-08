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
-- The `quiz` table does not have an RLS, but we're still
-- making `api` the owner of `quizzes`.
alter view quizzes owner to api;
