\echo # filling table data.assignment (3)
COPY data.assignment (slug,points_possible,title,body,closed_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
team-selection	50	Select your team	Lorem body lorem	2018-12-27 14:55:50
js-koans	50	JavaScript Koans	Lorem body lorem	2018-12-27 14:55:50
exam-1	50	First Exam	Lorem body lorem	2018-12-27 14:55:50
\.
-- 
-- analyze modified tables
ANALYZE data.assignment;