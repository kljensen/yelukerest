\echo # filling table quiz_question_option (6)
COPY data.quiz_question_option (id,quiz_question_id,quiz_id,slug,body,is_markdown,is_correct,created_at,updated_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	1	1	n-h	New Haven	FALSE	TRUE	2018-01-06 07:55:50	2018-01-06 07:55:50
2	1	1	bei	北京	FALSE	FALSE	2018-01-06 07:55:50	2018-01-06 07:55:50
3	2	1	cambridge-ma	Cambridge	FALSE	TRUE	2018-01-06 07:55:50	2018-01-06 07:55:50
4	2	1	shanghai	上海	FALSE	FALSE	2018-01-06 07:55:50	2018-01-06 07:55:50
5	3	2	berk	Berkeley	FALSE	TRUE	2018-01-06 07:55:50	2018-01-06 07:55:50
6	3	2	hanoi	Hà Nội	FALSE	FALSE	2018-01-06 07:55:50	2018-01-06 07:55:50
7	4	2	bei	Beijing with some code. `foo=5`. [Link](http://google.com). And\n\n```javascript\nlet bar=6;```	FALSE	FALSE	2018-01-06 07:55:50	2018-01-06 07:55:50
8	4	2	h-n	Hà Nội	FALSE	FALSE	2018-01-06 07:55:50	2018-01-06 07:55:50
9	4	2	prov1	Providence	FALSE	TRUE	2018-01-06 07:55:50	2018-01-06 07:55:50
10	4	2	prov2	Providence	FALSE	TRUE	2018-01-06 07:55:50	2018-01-06 07:55:50
\.

-- restart sequences
ALTER SEQUENCE data.quiz_question_option_id_seq RESTART WITH 7;
-- 
-- analyze modified tables
ANALYZE data.quiz_question_option;
