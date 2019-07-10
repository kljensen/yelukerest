\echo # filling table assignment_grade_exception (2)

-- Users 5 has an extension on team-selection and user 2 on project-update-1
COPY data.assignment_grade_exception (assignment_slug,user_id,team_nickname,closed_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
team-selection	5	\N	3019-12-27 14:55:50
project-update-1	\N	hazy-mountain	3019-12-27 14:55:50
\.

ANALYZE data.assignment_grade_exception;
