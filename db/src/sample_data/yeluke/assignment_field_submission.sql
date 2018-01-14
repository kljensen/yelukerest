\echo # filling table data.assignment_field_submission.sql (N)
COPY data.assignment_field_submission (assignment_submission_id,assignment_field_id,assignment_slug,body,submitter_user_id) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	1	team-selection	foobarsecret-bright-fog	1
2	1	team-selection	blah-secret-hazy-mountain	2
3	1	team-selection	foobarsecret-bright-fog	3
4	5	project-update-1	http://github.com/kljensen/fakerepo	1
4	6	project-update-1	http://docs.google.com/fakedoc	3
\.

-- analyze modified tables
ANALYZE data.assignment_field_submission;