grant select, insert, update, delete on data."user" to api;


alter table data.user enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy user_access_policy on data.user to api 
using (
	-- The student users can see on her or his user.
	(request.user_role() = 'student' and request.user_id() = id)
	or
	-- faculty and tas can see all users
	(request.user_role() = ANY('{faculty,ta}'::text[]))
	OR
	-- The authapp can view users
	(
		request.user_role() = 'app'
		AND
		request.app_name() = 'authapp'
	)
);

-- student users can select from this view. The RLS will
-- limit them to viewing their own users.
grant select on api.users to student, ta, app;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.users to faculty;