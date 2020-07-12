\echo # filling table grade

-- Users 5 has an extension on quiz 3
COPY data.grade(user_id,snapshot_slug,points,description,created_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	after-first-exam	50	woot!	2019-12-27 14:55:50
2	after-first-exam	60	woot!	2019-12-27 14:55:50
4	after-first-exam	90	woot!	2019-12-27 14:55:50
5	after-first-exam	100	woot!	2019-12-27 14:55:50
\.

ANALYZE data.grade;
