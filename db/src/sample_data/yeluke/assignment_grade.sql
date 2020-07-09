\echo # filling table assignment_grade (2)

-- Users 1 & 2 took the first assignment. Nobody took anything
-- else. Let's make user #1 get a 100% and user #2 get a 50%.
-- assignment #1 has two questions.
COPY data.assignment_grade (assignment_submission_id,assignment_slug,points,comments) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	team-selection	50	Foo bar bax boo this is your comment
2	team-selection	40	Grade comment
3	team-selection	20	
4	project-update-1	75	\N
\.

ANALYZE data.assignment_grade;
