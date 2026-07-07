CREATE OR REPLACE VIEW grade_snapshot_distributions AS
    SELECT
        snapshot_slug,
        COUNT(grade.user_id),
        avg(points) AS average,
        min(points),
        max(points),
        stddev_pop(points) AS stddev,
        array_agg(points ORDER BY points) AS grades
    FROM
        data.grade
        JOIN data."user"
            ON grade.user_id = "user".id
    WHERE role = 'student'
    GROUP BY snapshot_slug
    HAVING COUNT(grade.user_id) >= 3;

COMMENT ON VIEW grade_snapshot_distributions IS
    'Statistics on student grades for each grade snapshot';
COMMENT ON COLUMN grade_snapshot_distributions.snapshot_slug IS
    'The slug for the grade snapshot to which these statistics correspond';
COMMENT ON COLUMN grade_snapshot_distributions.count IS
    'The number of students with grades for this grade snapshot';
COMMENT ON COLUMN grade_snapshot_distributions.average IS
    'The average grade among students for this grade snapshot';
COMMENT ON COLUMN grade_snapshot_distributions.min IS
    'The minimum grade among students for this grade snapshot';
COMMENT ON COLUMN grade_snapshot_distributions.max IS
    'The maximum grade among students for this grade snapshot';
COMMENT ON COLUMN grade_snapshot_distributions.stddev IS
    'The population standard deviation of student grades for this grade snapshot';
COMMENT ON COLUMN grade_snapshot_distributions.grades IS
    'The student grades for this grade snapshot in ascending order';

-- NOTICE We do *NOT* alter the owner to API because
-- we will not have an RLS for grade_snapshot_distributions. This is
-- because then users would not be able to see accurate
-- stats because the RLS would flow through to the grade
-- table.
-- alter view grade_snapshot_distributions owner to api;
