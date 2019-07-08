\echo # filling table data.assignment_field_submission.sql (N)
COPY data.assignment_field_submission (assignment_submission_id,assignment_field_slug,assignment_slug,body,submitter_user_id) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	secret	team-selection	foobarsecret-bright-fog	1
2	secret	team-selection	blah-secret-hazy-mountain	2
3	secret	team-selection	foobarsecret-bright-fog	3
4	repo-url	project-update-1	http://github.com/kljensen/fakerepo	1
4	update-url	project-update-1	http://docs.google.com/fakedoc	3
\.

-- analyze modified tables
ANALYZE data.assignment_field_submission;