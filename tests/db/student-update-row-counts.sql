begin;
select plan(5);

SELECT set_eq(
    $$
        SELECT table_name::text
        FROM information_schema.role_table_grants
        WHERE table_schema = 'api'
        AND grantee = 'student'
        AND privilege_type = 'UPDATE'
    $$,
    ARRAY['assignment_field_submissions'],
    'students should only have UPDATE privileges on assignment field submissions'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT results_eq(
    $$
        WITH updated_rows AS (
            UPDATE api.assignment_field_submissions
            SET body = 'student-row-count-secret'
            WHERE assignment_slug = 'team-selection'
            RETURNING assignment_submission_id, assignment_field_slug
        )
        SELECT count(*)::integer
        FROM updated_rows
    $$,
    ARRAY[1],
    'student broad assignment update should affect only their own individual field submission'
);

SELECT results_eq(
    $$
        WITH updated_rows AS (
            UPDATE api.assignment_field_submissions
            SET body = 'http://student-row-count.example.com'
            WHERE assignment_slug = 'project-update-1'
            RETURNING assignment_submission_id, assignment_field_slug
        )
        SELECT count(*)::integer
        FROM updated_rows
    $$,
    ARRAY[2],
    'student broad team update should affect exactly their writable team field submissions'
);

set request.jwt.claim.user_id = '2';

SELECT results_eq(
    $$
        WITH updated_rows AS (
            UPDATE api.assignment_field_submissions
            SET body = 'http://wrong-team.example.com'
            WHERE assignment_slug = 'project-update-1'
            RETURNING assignment_submission_id, assignment_field_slug
        )
        SELECT count(*)::integer
        FROM updated_rows
    $$,
    ARRAY[0],
    'student broad team update should affect zero rows for another team'
);

set local role ta;
set request.jwt.claim.role = 'ta';
set request.jwt.claim.user_id = '1';

SELECT results_eq(
    $$
        WITH updated_rows AS (
            UPDATE api.assignment_field_submissions
            SET body = 'http://ta-row-count.example.com'
            WHERE assignment_slug = 'project-update-1'
            AND assignment_field_slug = 'repo-url'
            RETURNING assignment_submission_id, assignment_field_slug
        )
        SELECT count(*)::integer
        FROM updated_rows
    $$,
    ARRAY[1],
    'TA assignment field update should use the same RLS-narrowed row count'
);

select * from finish();
rollback;
