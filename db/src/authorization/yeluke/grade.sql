grant select, insert, update, delete on data.grade to api;

alter table data.grade enable row level security;

create policy grade_access_policy on data.grade to api
using (
    -- The student users can see all her/his own rows.
    (request.user_role() = ANY('{student,ta}'::text[]) and request.user_id() = user_id)
    or
    -- Faculty can see all
    (request.user_role() = 'faculty')
) WITH CHECK (
    -- Only faculty can write 
    request.user_role() = 'faculty'
);

grant select on api.grades to student, ta;
grant select, insert, update, delete on api.grades to faculty;
