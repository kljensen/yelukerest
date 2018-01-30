create or replace view assignment_grades as
    select * from data.assignment_grade;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `user` table should have RLS becuase students should not
-- see each others user grades.
alter view assignment_grades owner to api;
