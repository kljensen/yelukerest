\echo # filling table data.team (3)
COPY data.team (nickname,updated_at,created_at) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
bright-fog	2016-12-27 15:00:00	2016-12-27 14:55:50
damp-pond	2016-12-27 15:00:00	2016-12-27 12:00:00
hazy-mountain	2016-12-27 15:00:00	2016-12-27 12:00:00
\.

-- Add users to teeams
UPDATE data.user SET team_nickname = 'bright-fog' WHERE id=1;
UPDATE data.user SET team_nickname = 'hazy-mountain' WHERE id=2;
UPDATE data.user SET team_nickname = 'bright-fog' WHERE id=3;

-- analyze modified tables
ANALYZE data.team;
