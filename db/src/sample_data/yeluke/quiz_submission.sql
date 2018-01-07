\echo # filling table quiz_submission_id_seq (2)
COPY data.quiz_submission (quiz_id,user_id,created_at,updated_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	1	2018-01-06 07:55:50	2018-01-06 07:55:50
1	2	2018-01-06 07:54:50	2018-01-06 07:55:50
\.

-- 
-- analyze modified tables
ANALYZE data.quiz_submission;
