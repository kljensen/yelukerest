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
	(request.user_role() = 'student' and request.user_id() = user_id)

	or
	-- Faculty can see engagement by all users.
	(request.user_role() = 'faculty')
) WITH CHECK (
    -- Facutly can write to any row
	(request.user_role() = 'faculty')
	or
	(
		-- Students may only edit a quiz answer
        request.user_role() = 'student'
        and
        -- if it is for themselves
        request.user_id() = user_id
		and
        -- and the quiz is open for submission. 
        EXISTS(
            SELECT * 
            FROM api.quizzes as q
            JOIN api.quiz_submissions as qs
            ON (q.id = qs.quiz_id)
            WHERE (
                q.id = quiz_id and q.is_open
                and
                qs.created_at + q.duration > current_timestamp
                and
                qs.user_id = user_id
            )
		)
	)

);

-- NOTE: we are using a trigger to apply the time limits
-- associated with the quiz_answers. Doing so allows me
-- to not duplicate a lot of the RLS code above.

-- student users need to edit their answers
grant select, insert, delete on api.quiz_answers to student;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.quiz_answers to faculty;