\echo # filling table data.assignment_field (3)
COPY data.assignment_field (id,assignment_slug,label,help,placeholder,is_url,is_multiline) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	team-selection	Your team secret	Choose something unique	FOO-BAR-BAZ	FALSE	FALSE
2	js-koans	Your repo	SHould be on github	http://github.com...etc	TRUE	FALSE
3	exam-1	Your prose reponse	Say something profound	lots-o-text here	FALSE	FALSE
4	exam-1	Your repo	SHould be on github	http://github.com...etc	TRUE	FALSE
\.
-- 

ALTER SEQUENCE data.assignment_field_id_seq RESTART WITH 5;

-- analyze modified tables
ANALYZE data.assignment_field;