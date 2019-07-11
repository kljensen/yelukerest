create or replace view quiz_grade_exceptions as
    select * from data.quiz_grade_exception;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `user` table should have RLS becuase students should not
-- see each others user grades.
alter view quiz_grade_exceptions owner to api;