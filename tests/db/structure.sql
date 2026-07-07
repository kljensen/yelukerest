begin;
select * from no_plan();

select * from check_test(
    views_are('api', array[
        'platform_version',
        'artifacts', 'meetings', 'engagements', 'teams', 'users', 'quizzes',
        'quiz_submissions', 'quiz_submissions_info', 'ui_elements',
        'assignments', 'assignment_fields', 'assignment_submissions',
        'assignment_field_submissions', 'quiz_grades', 'assignment_grades',
        'quiz_grade_exceptions', 'assignment_grade_exceptions',
        'quiz_grade_distributions', 'assignment_grade_distributions',
        'user_secrets', 'user_jwts', 'grade_snapshots', 'grades'], 'tables present'),
    true,
    'all views are present in api schema',
    'tables present',
    ''
);

SELECT set_eq(
    format($$
        SELECT rolname
        FROM pg_roles
        WHERE rolname IN (
            'faculty',
            %L,
            'observer',
            'student',
            'superuser',
            'app',
            'anonymous',
            'api',
            'ta'
        )
    $$, :'authenticator_user'),
    ARRAY[
        'faculty',
        :'authenticator_user',
        'observer',
        'student',
        'superuser',
        'app',
        'anonymous',
        'api',
        'ta'
    ],
    'Yelukerest roles are present'
);

select * from finish();
rollback;
