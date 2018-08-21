-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.team to api;

-- Define the who can access team data.
-- Enable RLS on the table holding the data.
alter table data.team enable row level security;


-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy team_access_policy on data.team to api 
using (
	-- The student users can see only her or his team.
	-- This is a bit difficult to achieve. And, for this
	-- table, it is not necessary. It will be necessary
	-- for assignmentsubmissions, so I am working on it
	-- now here. References:
	-- https://stackoverflow.com/questions/42571569/row-level-security-in-postgres-on-normalized-tables
	(request.user_role() = ANY('{student,ta}'::text[]) AND (
		-- Below, we are asking the question, does the current row's
		-- nickname match the nickname of the user making this request.
		-- That user's `id` is in `request.user_id()` from the JWT.
		nickname = (
			SELECT team_nickname
			FROM api.users
			WHERE id=request.user_id()
		)
	))
	or
	-- faculty can see team by all users
	(request.user_role() = 'faculty')
);

-- student users can select from this view. The RLS will
-- limit them to viewing their own teams.
grant select on api.teams to student, ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.teams to faculty;
