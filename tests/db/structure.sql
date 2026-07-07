begin;
select * from no_plan();

select * from check_test(
    views_are('api', array[
        'meetings', 'engagements', 'teams', 'users', 'quizzes',
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

SELECT roles_are(ARRAY[
    'faculty',
    'authenticator',
    'observer',
    'student',
    'superuser',
    'app',
    'anonymous',
    'api',
    'ta',
    -- Everything below here is built-in/default
    'pg_monitor',
    'pg_stat_scan_tables',
    'pg_read_all_settings',
    'pg_signal_backend',
    'pg_read_all_stats',
    'pg_execute_server_program',
    'pg_write_server_files',
    'pg_read_server_files',
    'pg_database_owner',
    'pg_read_all_data',
    'pg_write_all_data'
]);

select * from finish();
rollback;
