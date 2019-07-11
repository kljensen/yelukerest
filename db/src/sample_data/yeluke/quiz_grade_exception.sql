\echo # filling table quiz_grade_exception (2)

-- Users 5 has an extension on quiz 3
COPY data.quiz_grade_exception (quiz_id,user_id,closed_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
3	5	3019-12-27 14:55:50
\.

ANALYZE data.quiz_grade_exception;
