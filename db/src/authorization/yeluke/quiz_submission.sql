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
	(request.user_role() = 'faculty')
	or
	(
		-- Students may only submit a quiz under three conditions:
		-- the user_id refers to themselves
		-- the quiz is open for submission (after open, before close, and not draft)
		request.user_role() = ANY('{student,ta}'::text[])
		AND (
			request.user_id() = user_id
			and
			EXISTS(
				SELECT q.id
				FROM api.quizzes q
				LEFT JOIN api.quiz_grade_exceptions qge ON (q.id = qge.quiz_id)
				WHERE (
					q.id = data.quiz_submission.quiz_id and
					(
						q.is_open
						or
						(
							qge.closed_at > current_timestamp
							AND
							q.is_draft = False
							AND
							q.open_at < current_timestamp
						)
					)
				)
			)
		)
	)

);

-- student users can select from this view. The RLS will
-- limit them to viewing their own quiz_submissions.
grant select, insert on api.quiz_submissions to student, ta;
-- grant select on api.quiz_info to student, ta, faculty;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.quiz_submissions to faculty;

-- The quiz_submissions_info view is read-only
grant select on api.quiz_submissions_info to student, ta, faculty;
