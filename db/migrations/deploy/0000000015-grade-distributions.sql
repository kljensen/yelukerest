START TRANSACTION;

SET search_path = api, pg_catalog;

CREATE VIEW assignment_grade_distributions AS
	SELECT sub.assignment_slug,
    count(sub.id) AS count,
    avg(assignment_grade.points) AS average,
    min(assignment_grade.points) AS min,
    max(assignment_grade.points) AS max,
    max(assignment_grade.points_possible) AS points_possible,
    stddev_pop(assignment_grade.points) AS stddev,
    array_agg(assignment_grade.points ORDER BY assignment_grade.points) AS grades
   FROM ((data.assignment_grade
     JOIN data.assignment_submission sub ON ((assignment_grade.assignment_submission_id = sub.id)))
     JOIN data."user" u ON (((sub.user_id = u.id) OR ((sub.team_nickname)::text = (u.team_nickname)::text))))
  WHERE (u.role = 'student'::data.user_role)
  GROUP BY sub.assignment_slug;

COMMENT ON VIEW assignment_grade_distributions IS 'Statics on the grades received by students for each assignment';

COMMENT ON COLUMN assignment_grade_distributions.assignment_slug IS 'The slug for the assignment to which these statistics correspond';

COMMENT ON COLUMN assignment_grade_distributions."count" IS 'The number of students with grades for this assignment';

COMMENT ON COLUMN assignment_grade_distributions.average IS 'The average grade among students for this assignment';

COMMENT ON COLUMN assignment_grade_distributions."min" IS 'The minmum grade among students for this assignment';

COMMENT ON COLUMN assignment_grade_distributions."max" IS 'The maximum grade among students for this assignment';

COMMENT ON COLUMN assignment_grade_distributions.points_possible IS 'The number of points possible for this assignment';

COMMENT ON COLUMN assignment_grade_distributions.stddev IS 'The standard deviation of student grades for this assignment';

COMMENT ON COLUMN assignment_grade_distributions.grades IS 'The grades received by students for this assignment in ascending order';
REVOKE ALL ON TABLE assignment_grade_distributions FROM student;
GRANT SELECT ON TABLE assignment_grade_distributions TO student;
REVOKE ALL ON TABLE assignment_grade_distributions FROM ta;
GRANT SELECT ON TABLE assignment_grade_distributions TO ta;
REVOKE ALL ON TABLE assignment_grade_distributions FROM faculty;
GRANT SELECT ON TABLE assignment_grade_distributions TO faculty;

CREATE VIEW quiz_grade_distributions AS
	SELECT quiz_grade.quiz_id,
    count(quiz_grade.user_id) AS count,
    avg(quiz_grade.points) AS average,
    min(quiz_grade.points) AS min,
    max(quiz_grade.points) AS max,
    max(quiz_grade.points_possible) AS points_possible,
    stddev_pop(quiz_grade.points) AS stddev,
    array_agg(quiz_grade.points ORDER BY quiz_grade.points) AS grades
   FROM (data.quiz_grade
     JOIN data."user" ON ((quiz_grade.user_id = "user".id)))
  WHERE ("user".role = 'student'::data.user_role)
  GROUP BY quiz_grade.quiz_id;

COMMENT ON VIEW quiz_grade_distributions IS 'Statics on the grades received by students for each quiz';

COMMENT ON COLUMN quiz_grade_distributions.quiz_id IS 'The slug for the quiz to which these statistics correspond';

COMMENT ON COLUMN quiz_grade_distributions."count" IS 'The number of students with grades for this quiz';

COMMENT ON COLUMN quiz_grade_distributions.average IS 'The average grade among students for this quiz';

COMMENT ON COLUMN quiz_grade_distributions."min" IS 'The minmum grade among students for this quiz';

COMMENT ON COLUMN quiz_grade_distributions."max" IS 'The maximum grade among students for this quiz';

COMMENT ON COLUMN quiz_grade_distributions.points_possible IS 'The number of points possible for this quiz';

COMMENT ON COLUMN quiz_grade_distributions.stddev IS 'The standard deviation of student grades for this quiz';

COMMENT ON COLUMN quiz_grade_distributions.grades IS 'The grades received by students for this quiz in ascending order';
REVOKE ALL ON TABLE quiz_grade_distributions FROM student;
GRANT SELECT ON TABLE quiz_grade_distributions TO student;
REVOKE ALL ON TABLE quiz_grade_distributions FROM ta;
GRANT SELECT ON TABLE quiz_grade_distributions TO ta;
REVOKE ALL ON TABLE quiz_grade_distributions FROM faculty;
GRANT SELECT ON TABLE quiz_grade_distributions TO faculty;

COMMIT TRANSACTION;
