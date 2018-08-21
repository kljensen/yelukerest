-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.assignment_grade to api;

-- Define the who can access assignment_grade data.
-- Enable RLS on the table holding the data.
alter table data.assignment_grade enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy assignment_grade_access_policy on data.assignment_grade to api 
using (
	( 
        -- If the role is student
        request.user_role() = ANY('{student,ta}'::text[])
        and 
        -- They can see rows in the assignment_grades table if
        -- they can see the assignment submission to which a
        -- particular row points. Here, we're relying on the
        -- RLS of api.assignment_submission.
        EXISTS (
            SELECT * FROM api.assignment_submissions as ass_sub
            WHERE assignment_submission_id = ass_sub.id
        )
    )
	OR
	-- faculty can see assignment_grade by all users
	(request.user_role() = 'faculty')
) WITH CHECK (
    request.user_role() = 'faculty'
);

-- student users can select from this view. The RLS will
-- limit them to viewing their own assignment_grades.
grant select on api.assignment_grades to student, ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.assignment_grades to faculty;
