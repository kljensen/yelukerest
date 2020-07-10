\echo # filling table grade_snapshot (2)

-- Users 5 has an extension on quiz 3
COPY data.grade_snapshot (slug,description,created_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
after-first-exam	woot!	2019-12-27 14:55:50
\.

ANALYZE data.grade_snapshot;
