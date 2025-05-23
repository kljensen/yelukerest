\echo # filling table quiz (2)
COPY data.quiz (id,meeting_slug,points_possible,is_draft,duration,open_at,closed_at,created_at,updated_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	intro	13	FALSE	10 minutes	2017-01-04 07:55:50	2017-12-06 07:55:50	2018-01-06 07:55:50	2018-01-06 07:55:50
2	structuredquerylang	13	FALSE	10 minutes	2018-01-04 07:54:50	3019-01-06 07:54:50	2018-01-06 07:54:50	2018-01-06 07:55:50
3	entrepreneurship-woot	13	TRUE	10 minutes	2018-01-04 07:54:50	3019-01-06 07:54:50	2018-01-06 07:54:50	2018-01-06 07:55:50
\.

-- Notice the second quiz closes in 3019!

-- restart sequences
ALTER SEQUENCE data.quiz_id_seq RESTART WITH 4;
-- 
-- analyze modified tables
ANALYZE data.quiz;
