-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.assignment_grade_exception to api;

-- Define the who can access assignment_grade_exception data.
-- Enable RLS on the table holding the data.
alter table data.assignment_grade_exception enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy assignment_grade_exception_access_policy on data.assignment_grade_exception to api 
using (
	-- The student users can see all her/his assignment_grade_exception items.
	(request.user_role() = ANY('{student,ta}'::text[]) AND 
        (NOT is_team AND request.user_id() = user_id)
        OR
        -- It is a team assignment and they are on that team
        -- Note that the table constraints ensure `team_nickname`
        -- is not null when `is_team` is TRUE.
        (is_team AND (
            EXISTS(
                SELECT * FROM api.users as u
                WHERE
                    u.id = request.user_id()
                    AND
                    u.team_nickname = assignment_grade_exception.team_nickname
            )
        ))
    )

	or
	-- faculty can see assignment_grade_exception by all users
	(request.user_role() = 'faculty')
) WITH CHECK (
    -- Only faculty have write permission
	request.user_role() = 'faculty'
);

-- student and ta users can select from this view. The RLS will
-- limit them to viewing their own assignment_grade_exceptions.
grant select on api.assignment_grade_exceptions to student, ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.assignment_grade_exceptions to faculty;