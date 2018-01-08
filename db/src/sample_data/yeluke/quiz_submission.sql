\echo # filling table quiz_submission_id_seq (2)
COPY data.quiz_submission (quiz_id,user_id) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	1
1	2
\.

-- 
-- analyze modified tables
ANALYZE data.quiz_submission;
