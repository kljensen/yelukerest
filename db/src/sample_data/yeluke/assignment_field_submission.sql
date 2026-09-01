\echo # filling table data.assignment_field_submission.sql (N)
-- `origin` is stated explicitly because this load runs over psql with no
-- request identity, and the defaults trigger refuses such a write unless the
-- writer says how the row came to exist (issue #370). The value follows the
-- submitter's role in users.sql: 1 and 2 are students writing their own work,
-- 3 is faculty, so those rows are staff writes.
COPY data.assignment_field_submission (assignment_submission_id,assignment_field_slug,assignment_slug,body,submitter_user_id,origin) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	secret	team-selection	foobarsecret-bright-fog	1	student
2	secret	team-selection	blah-secret-hazy-mountain	2	student
3	secret	team-selection	foobarsecret-bright-fog	3	staff
4	repo-url	project-update-1	http://github.com/kljensen/fakerepo	1	student
4	update-url	project-update-1	http://docs.google.com/fakedoc	3	staff
\.

-- analyze modified tables
ANALYZE data.assignment_field_submission;
