begin;
select plan(10);

SELECT view_owner_is(
    'api', 'grade_snapshot_distributions', 'superuser',
    'api.grade_snapshot_distributions view should be owned by the superuser role'
);

SELECT table_privs_are(
    'api', 'grade_snapshot_distributions', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.grade_snapshot_distributions"'
);

SELECT table_privs_are(
    'api', 'grade_snapshot_distributions', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on view "api.grade_snapshot_distributions"'
);

SELECT table_privs_are(
    'api', 'grade_snapshot_distributions', 'ta', ARRAY['SELECT'],
    'TAs should only be granted SELECT on view "api.grade_snapshot_distributions"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select snapshot_slug from api.grade_snapshot_distributions',
    '%permission denied%',
    'anonymous users should not be able to use the api.grade_snapshot_distributions view'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT snapshot_slug FROM api.grade_snapshot_distributions',
    ARRAY[]::text[],
    'students should not see grade snapshot stats for cohorts smaller than three students'
);

RESET ROLE;
INSERT INTO data."user" (id, email, netid, nickname, role)
VALUES (6, 'student6@yale.edu', 'stu6', 'quiet-river', 'student');
INSERT INTO data.grade (user_id, snapshot_slug, points, description)
VALUES (6, 'after-first-exam', 70, 'woot!');

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT results_eq(
    $$
        SELECT snapshot_slug, count::int, average, min, max, grades
        FROM api.grade_snapshot_distributions
        WHERE snapshot_slug = 'after-first-exam'
    $$,
    $$ VALUES ('after-first-exam', 3, 60::double precision, 50::real, 70::real, ARRAY[50::real, 60::real, 70::real]) $$,
    'grade snapshot distributions should include only student grades and sort the grade array'
);

SELECT throws_like(
    $$UPDATE api.grade_snapshot_distributions SET snapshot_slug = 'after-final' WHERE snapshot_slug = 'after-first-exam'$$,
    '%cannot update view%',
    'students should NOT be able to alter grade snapshot stats'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT throws_like(
    $$UPDATE api.grade_snapshot_distributions SET snapshot_slug = 'after-final' WHERE snapshot_slug = 'after-first-exam'$$,
    '%cannot update view%',
    'faculty should NOT be able to alter grade snapshot stats'
);

SELECT is_empty(
    $$
        SELECT relname || '.' || attname
        FROM pg_class
        JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        JOIN pg_attribute ON pg_attribute.attrelid = pg_class.oid
        WHERE nspname = 'api'
        AND relname = 'grade_snapshot_distributions'
        AND attnum > 0
        AND NOT attisdropped
        AND NULLIF(btrim(col_description(pg_attribute.attrelid, pg_attribute.attnum)), '') IS NULL
    $$,
    'grade snapshot distribution columns should have comments'
);

select * from finish();
rollback;
