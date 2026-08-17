-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.quiz_grade_exception to api;

-- Define the who can access quiz_grade_exception data.
-- Enable RLS on the table holding the data.
alter table data.quiz_grade_exception enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy quiz_grade_exception_access_policy on data.quiz_grade_exception to api 
using (
	-- The student users can see all her/his quiz_grade_exception items.
	(request.user_role() = ANY('{student,ta}'::text[]) AND (request.user_id() = user_id))
        OR
	-- faculty can see quiz_grade_exception by all users
	(request.user_role() = 'faculty')
) WITH CHECK (
    -- Only faculty have write permission
	request.user_role() = 'faculty'
);

-- student and ta users can select from this view. The RLS will
-- limit them to viewing their own quiz_grade_exceptions.
grant select on api.quiz_grade_exceptions to student, ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.quiz_grade_exceptions to faculty;
