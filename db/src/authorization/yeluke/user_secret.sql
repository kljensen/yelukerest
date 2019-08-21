-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.user_secret to api;

-- Define the who can access user_secret data.
-- Enable RLS on the table holding the data.
alter table data.user_secret enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy user_secret_access_policy on data.user_secret to api 
using (
	( 
        -- If the role is student
        request.user_role() = ANY('{student,ta}'::text[])
        -- They can see rows in the user_secrets table if
        and (
            -- The secret belongs to them
            (request.user_id() = user_id)
            or
            -- The secret belongs to their team
            EXISTS(
                SELECT u.id FROM api.users as u
                WHERE
                    u.id = request.user_id()
                    AND
                    u.team_nickname = user_secret.team_nickname
            )
        )
    )
	OR
	-- faculty can see user_secret by all users
	(request.user_role() = 'faculty')
) WITH CHECK (
    -- Only faculty can write secrets
    request.user_role() = 'faculty'
);

-- Students can read and faculty can read-write
grant select on api.user_secrets to student, ta;
grant select, insert, update, delete on api.user_secrets to faculty;
