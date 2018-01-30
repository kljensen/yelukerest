-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.assignment_submission to api;

-- Define the who can access assignment_submission data.
-- Enable RLS on the table holding the data.
alter table data.assignment_submission enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy assignment_submission_access_policy on data.assignment_submission to api 
using (
	( 
        -- If the role is student
        request.user_role() = 'student'
        -- They can see rows in the assignment_submissions table if
        and (
            -- It is an individual assignment and it has their user_id
            (NOT is_team AND request.user_id() = user_id)
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
                        u.team_nickname = assignment_submission.team_nickname
                )
            ))
        )
    )

	OR
	-- faculty can see assignment_submission by all users
	(request.user_role() = 'faculty')
) WITH CHECK (
    (request.user_role() = 'faculty')
    OR
    ( 
        -- If the role is student
        request.user_role() = 'student'
        -- They can write rows in the assignment_submissions table if
        and
            -- The assignment is open
			EXISTS(
				SELECT * 
				FROM api.assignments as a
				WHERE (
					a.slug = assignment_slug and a.is_open
				)
			)
        and (
            -- It is an individual assignment and it has their user_id
            (NOT is_team AND request.user_id() = user_id)
            or
            -- It is a team assignment and they are on the team
            -- for which they are making a submission
            (is_team AND (
                -- TODO: REFACTOR to reduce code duplication with the
                -- RLS policy above on reads.
                EXISTS(
                    SELECT * FROM api.users as u
                    WHERE
                        u.id = request.user_id()
                        AND
                        u.team_nickname = assignment_submission.team_nickname
                )
            ))
        )
    )
);

-- student users can select from this view. The RLS will
-- limit them to viewing their own assignment_submissions.
grant select, insert on api.assignment_submissions to student;

-- faculty have CRUD privileges
grant usage on data.assignment_submission_id_seq to faculty, student;
grant select, insert, update, delete on api.assignment_submissions to faculty;
