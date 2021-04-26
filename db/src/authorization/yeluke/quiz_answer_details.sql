-- Let the `api` role---the view owner---query the data
-- that we need to query for this view.
grant select on data.quiz to api;
grant select on data.user to api;
grant select on data.quiz_question_option to api;
grant select on data.quiz_answer to api;
grant select on data.quiz_submission to api;
grant select on data.quiz_grade_exception to api;
grant select on data.quiz_question to api;

grant select on api.quiz_answer_details to ta,faculty;
