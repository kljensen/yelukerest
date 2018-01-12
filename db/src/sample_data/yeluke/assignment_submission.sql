\echo # filling table assignment_submission_id_seq (4)
COPY data.assignment_submission (id,assignment_slug,is_team,user_id,team_nickname,submitter_user_id) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	team-selection	FALSE	1	\N	1
2	team-selection	FALSE	2	\N	2
3	team-selection	FALSE	3	\N	3
4	project-update-1	TRUE	\N	bright-fog	1
\.

ALTER SEQUENCE data.assignment_submission_id_seq RESTART WITH 5;

-- 
-- analyze modified tables
ANALYZE data.assignment_submission;
