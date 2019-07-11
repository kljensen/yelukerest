create or replace view assignment_grade_exceptions as
    select * from data.assignment_grade_exception;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `user` table should have RLS becuase students should not
-- see each others user grades.
alter view assignment_grade_exceptions owner to api;

create or replace view submittablity as
    SELECT ass_sub.id, api.users.id user_id
    FROM
        api.assignment_submissions AS ass_sub
    INNER JOIN api.users
        ON (
            ass_sub.user_id = api.users.id
            OR
            ass_sub.team_nickname = api.users.team_nickname
        )
    