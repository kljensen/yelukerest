create or replace view quizzes as
    select * from data.quiz;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `quiz` table does not have an RLS, but we're still
-- making `api` the owner of `quizzes`.
alter view quizzes owner to api;
