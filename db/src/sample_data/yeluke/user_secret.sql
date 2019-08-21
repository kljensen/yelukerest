
-- Fill table data.user_secret
\echo # filling table user_secret
COPY data.user_secret (user_id, team_nickname, slug, body) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
2	\N	foo	bar2
1	\N	foo	bar1
\N	bright-fog	baz	wuz
\.

-- analyze modified tables
ANALYZE data.user_secret;
