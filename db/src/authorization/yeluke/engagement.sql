-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.engagement to api;

-- Define the who can access engagement data.
-- Enable RLS on the table holding the data.
alter table data.engagement enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy engagement_access_policy on data.engagement to api 
using (
	-- The student users can see all her/his engagement items.
	-- Notice how the rule changes based on the current user_id
	-- which is specific to each individual request
	(request.user_role() = 'student' and request.user_id() = user_id)

	or
	-- faculty and TAs can read/write engagement by all users
	(request.user_role() = ANY('{faculty,ta}'::text[]))
);

-- student users can select from this view. The RLS will
-- limit them to viewing their own engagements.
grant select on api.engagements to student;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.engagements to faculty, ta;
