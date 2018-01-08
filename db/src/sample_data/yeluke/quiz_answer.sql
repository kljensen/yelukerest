\echo # filling table quiz_answer (6)
-- Users 1 & 2 took the first quiz. Nobody took anything
-- else. Let's make user #1 get a 100% and user #2 get a 50%.
-- Quiz #1 has two questions.
COPY data.quiz_answer (quiz_id,user_id,quiz_question_option_id) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	1	1
1	1	3
1	2	1
1	2	2
\.
-- COPY data.quiz_question_option (id,quiz_question_id,quiz_id,body,is_markdown,is_correct,created_at,updated_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
-- 1	1	1	New Haven	FALSE	TRUE	2018-01-06 07:55:50	2018-01-06 07:55:50
-- 2	1	1	北京	FALSE	FALSE	2018-01-06 07:55:50	2018-01-06 07:55:50
-- 3	2	1	Cambridge	FALSE	TRUE	2018-01-06 07:55:50	2018-01-06 07:55:50
-- 4	2	1	上海	FALSE	FALSE	2018-01-06 07:55:50	2018-01-06 07:55:50
-- 5	3	2	Berkeley	FALSE	TRUE	2018-01-06 07:55:50	2018-01-06 07:55:50
-- 6	3	2	Hà Nội	FALSE	FALSE	2018-01-06 07:55:50	2018-01-06 07:55:50
-- \.

-- -- restart sequences
-- ALTER SEQUENCE data.quiz_question_option_id_seq RESTART WITH 7;
-- -- 
-- analyze modified tables
ANALYZE data.quiz_answer;
