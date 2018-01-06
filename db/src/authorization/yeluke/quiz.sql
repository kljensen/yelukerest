-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.quiz to api;

-- No need to row level security on quiz.

-- student users can select from this view. The RLS will
-- limit them to viewing their own quizzes.
grant select on api.quizzes to student;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.quizzes to faculty;
grant usage on data.quiz_id_seq to student, faculty;