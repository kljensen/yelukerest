-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.quiz_submission to api;

-- Define the who can access quiz_submission data.
-- Enable RLS on the table holding the data.
alter table data.quiz_submission enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy quiz_submission_access_policy on data.quiz_submission to api 
using (
	-- The student users can see all her/his quiz_submission items.
	(request.user_role() = ANY('{student,ta}'::text[]) and request.user_id() = user_id)

	or
	-- faculty can see quiz_submission by all users
	(request.user_role() = 'faculty')
	) WITH CHECK (
		-- Paper quiz submissions are created by faculty/admin grade imports,
		-- not by student online quiz-taking.
		request.user_role() = 'faculty'
	);

-- student users can select from this view. The RLS will
-- limit them to viewing their own quiz_submissions.
grant select on api.quiz_submissions to student, ta;
-- grant select on api.quiz_info to student, ta, faculty;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.quiz_submissions to faculty;
