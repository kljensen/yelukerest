-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.quiz_question_option to api;

-- Define the who can access quiz_question_option data.
-- Enable RLS on the table holding the data.
alter table data.quiz_question_option enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy quiz_question_option_access_policy on data.quiz_question_option to api 
using (

	(
        -- TODO: REDUCE the code duplication here. This policy
        -- is the exact same as the quiz_question policy. We
        -- shoud find some way to refactor this into a function.
        request.user_role() = ANY('{student,ta}'::text[])
        AND EXISTS(
            SELECT qs.quiz_id, qs.user_id FROM api.quiz_submissions AS qs
            WHERE
                -- It is the current user
                (qs.user_id = request.user_id()
                AND
                -- and it is the current quiz
                --  this `quiz_id` is being taken from qs,
                -- whereas I want it from quiz_question_option
                quiz_question_option.quiz_id = qs.quiz_id)
        )
    )

	or
	-- faculty can see quiz_question_option by all users
	(request.user_role() = 'faculty')
);

-- student users can select from this view. The RLS will
-- limit them to viewing their own quiz_question_options.
grant select (id,quiz_question_id,quiz_id,body,is_markdown,created_at,updated_at) on api.quiz_question_options to student, ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.quiz_question_options to faculty;
grant usage on data.quiz_question_option_id_seq to student, ta, faculty;