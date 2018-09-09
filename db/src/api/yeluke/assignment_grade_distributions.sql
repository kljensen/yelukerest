
CREATE OR REPLACE VIEW assignment_grade_distributions AS
    SELECT
        sub.assignment_slug,
        COUNT(sub.id), -- Any field fine here. "*" is a PITA with migrations
        avg(points) AS average,
        min(points),
        max(points),
        max(points_possible) AS points_possible,
        stddev_pop(points) AS stddev,
        array_agg(points ORDER BY points) AS grades
    FROM    
        data.assignment_grade
            JOIN data.assignment_submission sub
            ON assignment_submission_id=sub.id
            JOIN data.user u
            ON (sub.user_id = u.id OR sub.team_nickname = u.team_nickname)
    WHERE role='student'
    GROUP BY sub.assignment_slug;

COMMENT ON VIEW assignment_grade_distributions IS
    'Statics on the grades received by students for each assignment';
COMMENT ON COLUMN assignment_grade_distributions.assignment_slug IS
    'The slug for the assignment to which these statistics correspond';
COMMENT ON COLUMN assignment_grade_distributions.count IS
    'The number of students with grades for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.average IS
    'The average grade among students for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.min IS
    'The minmum grade among students for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.max IS
    'The maximum grade among students for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.points_possible IS
    'The number of points possible for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.stddev IS
    'The standard deviation of student grades for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.grades IS
    'The grades received by students for this assignment in ascending order';

-- NOTICE We do *NOT* alter the owner to API because
-- we will not have an RLS for assignment_grade_distributions. This is
-- because then users would not be able to see accurate
-- stats because the RLS would flow through to the assignment_grade
-- table.
-- alter view assignment_grade_distributions owner to api;
