select * from no_plan();

SELECT set_eq(
    $$
        SELECT relname
        FROM pg_class
        JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE nspname = 'api'
          AND relkind IN ('v', 'm')
    $$,
    ARRAY[
        'platform_version',
        'artifacts', 'meetings', 'engagements', 'teams', 'users', 'quizzes',
        'quiz_submissions', 'ui_elements',
        'assignments', 'assignment_fields', 'assignment_submissions',
        'assignment_field_submissions', 'assignment_field_submission_events',
        'quiz_grades', 'assignment_grades',
        'quiz_grade_events', 'assignment_grade_events', 'grade_events',
        'assignment_grade_exceptions',
        'quiz_grade_distributions', 'assignment_grade_distributions',
        'grade_snapshot_distributions',
        'mcp_jwt_mint_events', 'mcp_jwt_mint_anomalies', 'mcp_grant_revocations',
        'user_secrets', 'user_jwts', 'grade_snapshots', 'grades',
        'assignment_repositories',
        'assignment_repository_snapshots', 'assignment_repository_snapshots_due',
        'user_api_tokens'
    ]::text[],
    'all views are present in api schema'
);

SELECT set_eq(
    $$
        SELECT rolname
        FROM pg_roles
        WHERE rolname IN (
            'faculty',
            'observer',
            'student',
            'app',
            'anonymous',
            'api',
            'ta'
        )
    $$,
    ARRAY[
        'faculty',
        'observer',
        'student',
        'app',
        'anonymous',
        'api',
        'ta'
    ]::text[],
    'fixed Yelukerest roles are present'
);

SELECT set_eq(
    $$
        SELECT granted.rolname
        FROM pg_auth_members membership
        JOIN pg_roles granted ON granted.oid = membership.roleid
        JOIN pg_roles member ON member.oid = membership.member
        WHERE member.rolcanlogin
          AND granted.rolname IN ('anonymous', 'app', 'faculty', 'observer', 'student', 'ta')
    $$,
    ARRAY['anonymous', 'app', 'faculty', 'observer', 'student', 'ta']::text[],
    'the provisioned authenticator inherits every runtime role'
);

SELECT is_empty(
    $$
        SELECT relname
        FROM pg_class
        INNER JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE nspname = 'api'
        AND relkind IN ('v', 'm')
        AND NULLIF(btrim(obj_description(pg_class.oid, 'pg_class')), '') IS NULL
    $$,
    'all API views have comments'
);

SELECT is_empty(
    $$
        SELECT pg_class.relname || '.' || pg_attribute.attname
        FROM pg_class
        INNER JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        INNER JOIN pg_attribute ON pg_attribute.attrelid = pg_class.oid
        WHERE nspname = 'api'
        AND relkind IN ('v', 'm')
        AND pg_attribute.attnum > 0
        AND NOT pg_attribute.attisdropped
        AND NULLIF(btrim(col_description(pg_attribute.attrelid, pg_attribute.attnum)), '') IS NULL
    $$,
    'all API view columns have comments'
);

select * from finish();
