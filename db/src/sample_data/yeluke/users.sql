
-- Fill table data.user. Notice that we're not yet setting the 
-- team_nickname foreign key. That column will be added later
-- when that table is created.
\echo # filling table user (4)
COPY data."user" (id,email,netid,"name",known_as,nickname,"role",created_at,updated_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	alice@yale.edu	abc123	Alice Miller	Alice	bright-horse	student	2017-12-27 19:14:36	2017-12-27 19:15:36
2	bob@yale.edu	bde456	Robert Foo	Bob	silly-seahorse	student	2017-12-27 19:13:36	2017-12-27 19:14:36
5	charlotte@yale.edu	crt43	Charlotte Baz	Char	delighted-bear	observer	2017-12-27 19:13:36	2017-12-27 19:14:36
3	kyle.jensen@yale.edu	klj39	Kyle Jensen	Kyle	shiny-turd	faculty	2017-12-27 19:13:36	2017-12-27 19:14:36
4	jacob.bendicksen@yale.edu	jlb325	Jacob Bendicksen	Jacob	live-wire	faculty	2017-12-27 19:13:36	2017-12-27 19:14:36
\.

-- restart sequences
ALTER SEQUENCE data.user_id_seq RESTART WITH 6;
-- 
-- analyze modified tables
ANALYZE data.user;
