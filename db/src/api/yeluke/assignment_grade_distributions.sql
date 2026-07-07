
CREATE OR REPLACE VIEW assignment_grade_distributions AS
    WITH included_scores AS (
        SELECT
            assignment.slug AS assignment_slug,
            assignment.points_possible,
            COALESCE(assignment_grade.points, 0) AS points
        FROM
            data.assignment
            JOIN data."user" AS student
                ON student.role = 'student'
            LEFT JOIN data.assignment_submission AS sub
                ON sub.assignment_slug = assignment.slug
                AND NOT sub.is_team
                AND sub.user_id = student.id
            LEFT JOIN data.assignment_grade
                ON assignment_grade.assignment_submission_id = sub.id
        WHERE NOT assignment.is_team
        AND NOT assignment.is_draft

        UNION ALL

        SELECT
            sub.assignment_slug,
            assignment.points_possible,
            COALESCE(assignment_grade.points, 0) AS points
        FROM
            data.assignment_submission AS sub
            JOIN data.assignment
                ON assignment.slug = sub.assignment_slug
                AND assignment.is_team
                AND NOT assignment.is_draft
            JOIN data.assignment_submission_participant AS participant
                ON participant.assignment_submission_id = sub.id
            JOIN data."user" AS student
                ON participant.user_id = student.id
                AND student.role = 'student'
            LEFT JOIN data.assignment_grade
                ON assignment_grade.assignment_submission_id = sub.id
    )
    SELECT
        assignment_slug,
        COUNT(*), -- Counts included student scores, including zeroes for missing individual work.
        avg(points) AS average,
        min(points),
        max(points),
        MAX(points_possible) AS points_possible,
        stddev_pop(points) AS stddev,
        array_agg(points ORDER BY points) AS grades
    FROM included_scores
    GROUP BY assignment_slug
    HAVING COUNT(*) >= 3;

COMMENT ON VIEW assignment_grade_distributions IS
    'Statics on the grades received by students for each assignment';
COMMENT ON COLUMN assignment_grade_distributions.assignment_slug IS
    'The slug for the assignment to which these statistics correspond';
COMMENT ON COLUMN assignment_grade_distributions.count IS
    'The number of student scores included for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.average IS
    'The average score among included students for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.min IS
    'The minmum grade among students for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.max IS
    'The maximum grade among students for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.points_possible IS
    'The number of points possible for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.stddev IS
    'The standard deviation of included student scores for this assignment';
COMMENT ON COLUMN assignment_grade_distributions.grades IS
    'The included student scores for this assignment in ascending order';

-- NOTICE We do *NOT* alter the owner to API because
-- we will not have an RLS for assignment_grade_distributions. This is
-- because then users would not be able to see accurate
-- stats because the RLS would flow through to the assignment_grade
-- table.
-- alter view assignment_grade_distributions owner to api;
