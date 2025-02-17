-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.assignment_field_submission to api;

-- Define the who can access assignment_field_submission data.
-- Enable RLS on the table holding the data.
alter table data.assignment_field_submission enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy assignment_field_submission_access_policy on data.assignment_field_submission to api 
using (
	( 
        -- If the role is student
        request.user_role() = ANY('{student,ta}'::text[])
        AND
        (
            -- It was submitted by them
            submitter_user_id = request.user_id()
            OR
            -- The assignment submission is owned or submitted by them
            EXISTS(
                -- This query finds all assignment_submissions owned by
                -- this user or their team that have the current 
                -- assignment_submission_id
                SELECT ass_sub.id from
                    api.assignment_submissions AS ass_sub INNER JOIN api.users
                ON (
                    ass_sub.user_id = api.users.id
                    OR
                    ass_sub.team_nickname = api.users.team_nickname
                ) WHERE (
                    -- It is this user
                    api.users.id = request.user_id()
                    and
                    -- And this assignment submission
                    ass_sub.id = assignment_submission_id
                )
            )
            -- In the RLS policy here, we're also depending upon the 
            -- many constraints in the assignment_submission table,
            -- eg. that an assignment submission must be owned by a
            -- exactly one user or team.
        )
    )

	OR
	-- faculty can see by all users
	(request.user_role() = 'faculty')
) WITH CHECK (
    (request.user_role() = 'faculty')
    OR
    ( 
        -- TODO: The below is annoying to me and it 
        -- makes me thinkg we could move a lot of the `is_open`
        -- logic into triggers, which would complement the 
        -- `USING` clause of the RLS, above. In the query below
        -- all I'm doing is changing the query above to insist
        -- that the assignment is open. This may be better
        -- accomplished in a trigger that runs as a complement
        -- to the RLS, since we don't have any conditions where
        -- a student may not read that which they are allowed to 
        -- write.

        -- If the role is student
        request.user_role() = ANY('{student,ta}'::text[])
        AND (
            -- They can only submit fields as themselves
            submitter_user_id = request.user_id()
            AND
            -- Same query as above, but also insisting
            -- that the assignment be open
            EXISTS(
                SELECT ass_sub.id from
                    api.assignment_submissions AS ass_sub INNER JOIN api.users
                ON (
                    ass_sub.user_id = api.users.id
                    OR
                    ass_sub.team_nickname = api.users.team_nickname
                )
                INNER JOIN api.assignments
                ON (
                        api.assignments.slug = ass_sub.assignment_slug
                )
                LEFT JOIN api.assignment_grade_exceptions AS ge
                ON (
                    ge.assignment_slug = ass_sub.assignment_slug
                    AND
                    (
                        (ass_sub.is_team AND ge.team_nickname = ass_sub.team_nickname)
                        OR
                        (NOT ass_sub.is_team AND ge.user_id = ass_sub.user_id)
                    )
                )
                WHERE (
                    api.users.id = request.user_id()
                    AND
                    ass_sub.id = assignment_submission_id
                    AND (
                        api.assignments.is_open = true
                        OR
                        (
                            (ge.user_id = ass_sub.user_id
                            OR
                            ge.team_nickname = ass_sub.team_nickname)
                            AND
                            ge.closed_at > current_timestamp
                        )
                    )
                )
            )
        )
    )
);

-- student users can select from this view. The RLS will
-- limit them to viewing their own assignment_field_submissions.
grant select, insert, update on api.assignment_field_submissions to student, ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.assignment_field_submissions to faculty;
-- grant select, insert, update, delete on api.assignment_field_submissions to faculty;
