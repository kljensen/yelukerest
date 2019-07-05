\echo # filling table data.engagement (3)
COPY data.engagement (user_id,meeting_slug,participation,updated_at,created_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	intro	absent	2017-12-27 15:00:00	2017-12-27 14:55:50
2	intro	attended	2017-12-27 16:00:00	2017-12-27 14:53:50
3	intro	contributed	2017-12-27 17:30:00	2017-12-27 14:53:50
1	structuredquerylang	absent	2017-12-27 15:00:00	2017-12-27 12:00:00
2	structuredquerylang	attended	2017-12-27 16:00:00	2017-12-27 14:53:50
3	structuredquerylang	contributed	2017-12-27 17:30:00	2017-12-27 14:53:50
1	entrepreneurship-woot	absent	2017-12-27 15:00:00	2017-12-27 12:00:00
2	entrepreneurship-woot	attended	2017-12-27 16:00:00	2017-12-27 14:53:50
3	entrepreneurship-woot	led	2017-12-27 17:30:00	2017-12-27 14:53:50
\.

-- Above, the first user is consistently absent.

-- analyze modified tables
ANALYZE data.engagement;
