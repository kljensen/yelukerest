\echo # filling table assignment_grade (2)

-- Users 1 & 2 took the first assignment. Nobody took anything
-- else. Let's make user #1 get a 100% and user #2 get a 50%.
-- assignment #1 has two questions.
COPY data.assignment_grade (assignment_submission_id,assignment_slug,points) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
1	team-selection	50
2	team-selection	40
3	team-selection	20
4	project-update-1	75
\.

ANALYZE data.assignment_grade;
