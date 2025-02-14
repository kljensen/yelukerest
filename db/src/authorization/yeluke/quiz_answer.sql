-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.quiz_answer to api;

-- Define the who can access quiz_answer data.
-- Enable RLS on the table holding the data.
alter table data.quiz_answer enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy quiz_answer_access_policy on data.quiz_answer to api 
using (
	-- The student users can see all her/his answers.
	(request.user_role() = ANY('{student,ta}'::text[]) and request.user_id() = user_id)

	or
	-- Faculty can see quiz answers by all users.
	(request.user_role() = 'faculty')
) WITH CHECK (
    -- Facutly can write to any row
	(request.user_role() = 'faculty')
	or
	(
		-- Students may only edit a quiz answer
        request.user_role() = ANY('{student,ta}'::text[])
        and
        -- if it is for themselves
        request.user_id() = user_id
		and
        -- and the quiz is open for submission. 
        EXISTS(
            SELECT qsi.quiz_id, qsi.user_id 
            FROM api.quiz_submissions_info as qsi
            WHERE (
                qsi.quiz_id = quiz_id
                AND
                qsi.is_open 
                AND
                qsi.user_id = user_id
            )
		)
	)

);

-- student users need to edit their answers
grant select, insert, delete on api.quiz_answers to student, ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.quiz_answers to faculty;