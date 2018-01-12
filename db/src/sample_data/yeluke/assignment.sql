\echo # filling table data.assignment (3)
COPY data.assignment (slug,is_team,points_possible,title,body,closed_at,is_draft) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
team-selection	FALSE	50	Select your team	Lorem body lorem	3018-12-27 14:55:50	FALSE
js-koans	FALSE	50	JavaScript Koans	Lorem body lorem	3018-12-27 14:55:50	TRUE
exam-1	FALSE	50	First Exam	Lorem body lorem	3018-12-27 14:55:50	FALSE
project-update-1	TRUE	75	First Project update	big lorem here	3018-12-27 14:55:50	FALSE
\.
-- 
-- analyze modified tables
ANALYZE data.assignment;