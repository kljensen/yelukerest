\echo # filling table quiz_question (2)
COPY data.quiz_question (id,quiz_id,is_markdown,body,created_at,updated_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	1	FALSE	In what city is Yale located?	2018-01-06 07:55:50	2018-01-06 07:55:50
2	1	FALSE	In what city is Harvard located?	2018-01-06 07:55:50	2018-01-06 07:55:50
3	2	FALSE	In what city is UC Berkeley located?	2018-01-06 07:55:50	2018-01-06 07:55:50
4	2	FALSE	In what city is Brown located?	2018-01-06 07:55:50	2018-01-06 07:55:50
\.

-- Notice the second quiz_question closes in 3019!

-- restart sequences
ALTER SEQUENCE data.quiz_question_id_seq RESTART WITH 3;
-- 
-- analyze modified tables
ANALYZE data.quiz_question;
