\echo # filling table grade_exception (2)
COPY data.grade_exception (quiz_id,assignment_slug,is_team,user_id,team_nickname) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	\N	\N	5	\N
\N	project-update-1	TRUE	\N	hazy-mountain
\N	exam-1	FALSE	5	\N
\.

-- Notice the second quiz closes in 3019!

-- restart sequences
ALTER SEQUENCE data.quiz_id_seq RESTART WITH 4;
-- 
-- analyze modified tables
ANALYZE data.quiz;
