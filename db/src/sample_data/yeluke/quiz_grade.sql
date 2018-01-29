\echo # filling table quiz_grade (2)

-- Users 1 & 2 took the first quiz. Nobody took anything
-- else. Let's make user #1 get a 100% and user #2 get a 50%.
-- Quiz #1 has two questions.
COPY data.quiz_grade (quiz_id,user_id,points) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	1	13
1	2	0
\.

ANALYZE data.quiz_grade;
