\echo # filling table data.assignment_field
COPY data.assignment_field (slug,assignment_slug,label,help,placeholder,is_url,is_multiline,example) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
secret	team-selection	Your team secret	Choose something unique	FOO-BAR-BAZ	FALSE	FALSE	your-secret-here
repo-url	js-koans	Your repo	SHould be on github	http://github.com...etc	TRUE	FALSE	https://foo.com
profound	exam-1	Your prose reponse	Say something profound	lots-o-text here	FALSE	FALSE	example profound statement
url	exam-1	Your repo	SHould be on github	http://github.com...etc	TRUE	FALSE	https://github.com/foo
repo-url	project-update-1	team-repo	Should be on class github	http://github.com	TRUE	FALSE	http://bar.com/baz/?foo
update-url	project-update-1	sprint-report	A google doc	http://docs.google.com	TRUE	FALSE	https://www.yale.edu
\.
COPY data.assignment_field (slug,assignment_slug,label,help,placeholder,is_url,is_multiline,example,pattern) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
fooword	exam-1	Your word that includes foo	Your submission should include "foo"	...foo...	FALSE	FALSE	https://github.com/foo	.*foo.*
\.

-- analyze modified tables
ANALYZE data.assignment_field;