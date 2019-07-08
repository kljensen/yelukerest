\echo # filling table data.assignment_field (3)
COPY data.assignment_field (slug,assignment_slug,label,help,placeholder,is_url,is_multiline) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
secret	team-selection	Your team secret	Choose something unique	FOO-BAR-BAZ	FALSE	FALSE
repo-url	js-koans	Your repo	SHould be on github	http://github.com...etc	TRUE	FALSE
profound	exam-1	Your prose reponse	Say something profound	lots-o-text here	FALSE	FALSE
url	exam-1	Your repo	SHould be on github	http://github.com...etc	TRUE	FALSE
repo-url	project-update-1	team-repo	Should be on class github	http://github.com	TRUE	FALSE
update-url	project-update-1	sprint-report	A google doc	http://docs.google.com	TRUE	FALSE
\.

-- analyze modified tables
ANALYZE data.assignment_field;