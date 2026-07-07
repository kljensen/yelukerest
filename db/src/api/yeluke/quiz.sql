create or replace view quizzes
with (security_barrier = true) as
    select
        quiz.*,
        (
            quiz.is_draft = false and
            quiz.open_at < current_timestamp and
            current_timestamp < quiz.closed_at
        ) AS is_open
    from data.quiz
    where request.user_role() = 'faculty'
    or quiz.is_draft = false;

-- It is important to set the correct owner so the RLS policy kicks in.
alter view quizzes owner to api;
