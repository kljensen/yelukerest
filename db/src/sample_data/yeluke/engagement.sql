\echo # filling table data.engagement (3)
COPY data.engagement (user_id,meeting_id,participation,updated_at,created_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	1	absent	2017-12-27 15:00:00	2017-12-27 14:55:50
2	1	attended	2017-12-27 16:00:00	2017-12-27 14:53:50
3	1	contributed	2017-12-27 17:30:00	2017-12-27 14:53:50
1	2	absent	2017-12-27 15:00:00	2017-12-27 12:00:00
2	2	attended	2017-12-27 16:00:00	2017-12-27 14:53:50
3	2	contributed	2017-12-27 17:30:00	2017-12-27 14:53:50
1	3	absent	2017-12-27 15:00:00	2017-12-27 12:00:00
2	3	attended	2017-12-27 16:00:00	2017-12-27 14:53:50
3	3	led	2017-12-27 17:30:00	2017-12-27 14:53:50
\.

-- Above, the first user is consistently absent.

-- analyze modified tables
ANALYZE data.engagement;
