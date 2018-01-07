-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.quiz_question to api;

-- Define the who can access quiz_question data.
-- Enable RLS on the table holding the data.
alter table data.quiz_question enable row level security;

-- Define the RLS policy controlling what rows are visible to a
-- particular user.
create policy quiz_question_access_policy on data.quiz_question to api 
using (

	(
        -- Students can only see questions for a quiz
        -- that they have already begun. That is, quizzes
        -- for which they have a quiz submission.
        -- TODO: See if this is as inefficient as I expect it is.
        -- Also, I received this note from R. Talpa:
        -- "First thing to do is maybe to not reference api views in
        -- the rls policies, it will be hard to figure out what rules
        -- are applied, try and teference only tables from data in
        -- your rls". However, when I change `api` below to `data`
        -- I find that permission is denied.
        request.user_role() = 'student' and
        EXISTS(
            SELECT * FROM api.quiz_submissions AS qs
            WHERE
                -- It is the current user
                (qs.user_id = request.user_id()
                AND
                -- and it is the current quiz
                --  this `quiz_id` is being taken from qs,
                -- whereas I want it from quiz_question
                quiz_question.quiz_id = qs.quiz_id)
        )
    )

	or
	-- faculty can see quiz_question by all users
	(request.user_role() = 'faculty')
);

-- student users can select from this view. The RLS will
-- limit them to viewing their own quiz_questions.
grant select on api.quiz_questions to student;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.quiz_questions to faculty;
grant usage on data.quiz_question_id_seq to student, faculty;