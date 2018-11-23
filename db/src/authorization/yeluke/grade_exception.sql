-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.grade_exception to api;

-- Define the who can access grade_exception data.
-- Enable RLS on the table holding the data.
alter table data.grade_exception enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy grade_exception_access_policy on data.grade_exception to api 
using (
	( 
        -- If the role is student
        request.user_role() = ANY('{student,ta}'::text[])
        -- They can see rows in the grade_exceptions table if
        and (
            -- It is a quiz or an individual assignment and it has their user_id
            (request.user_id() = user_id)
            or
            -- It is a team assignment and they are on that team
            -- Note that the table constraints ensure `team_nickname`
            -- is not null when `is_team` is TRUE.
            (is_team AND (
                EXISTS(
                    SELECT * FROM api.users as u
                    WHERE
                        u.id = request.user_id()
                        AND
                        u.team_nickname = grade_exception.team_nickname
                )
            ))
        )
    )

	OR
	-- faculty can see all grade_exceptions
	(request.user_role() = 'faculty')
);

-- student users can select from this view. The RLS will
-- limit them to viewing their own grade_exceptions.
grant select on api.grade_exceptions to student, ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.grade_exceptions to faculty;
