-- Verify yelukerest:ddl on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'api') THEN
        RAISE EXCEPTION 'missing api schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'data') THEN
        RAISE EXCEPTION 'missing data schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN
        RAISE EXCEPTION 'missing auth schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'settings') THEN
        RAISE EXCEPTION 'missing settings schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'request') THEN
        RAISE EXCEPTION 'missing request schema';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgjwt') THEN
        RAISE EXCEPTION 'missing pgjwt schema';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_submission'
    ) THEN
        RAISE EXCEPTION 'missing data.assignment_submission table';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_submission'
        AND a.attname = 'is_team'
        AND a.attnotnull
    ) THEN
        RAISE EXCEPTION 'data.assignment_submission.is_team is not NOT NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_proc p ON p.oid = t.tgfoid
        JOIN pg_namespace pn ON pn.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_grade'
        AND t.tgname = 'tg_assignment_grade_default'
        AND pn.nspname = 'data'
        AND p.proname = 'fill_assignment_grade_defaults'
        AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION 'missing data.assignment_grade default trigger';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_proc p ON p.oid = t.tgfoid
        JOIN pg_namespace pn ON pn.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_field_submission'
        AND t.tgname = 'tg_assignment_field_submission_default'
        AND pn.nspname = 'data'
        AND p.proname = 'fill_assignment_field_submission_defaults'
        AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION 'missing data.assignment_field_submission default trigger';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.proname = 'ensure_student_engagement_rows'
        AND p.prosecdef
        AND p.proconfig @> ARRAY['search_path=data, pg_temp']
    ) THEN
        RAISE EXCEPTION 'missing security-definer data.ensure_student_engagement_rows function';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_proc p ON p.oid = t.tgfoid
        JOIN pg_namespace pn ON pn.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'user'
        AND t.tgname = 'tg_user_student_engagement_rows'
        AND pn.nspname = 'data'
        AND p.proname = 'ensure_student_engagement_rows'
        AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION 'missing data.user student engagement maintenance trigger';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'meeting'
        AND con.conname = 'meeting_duration_positive'
        AND con.contype = 'c'
    ) THEN
        RAISE EXCEPTION 'data.meeting must reject zero or negative duration';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'grade'
        AND con.conname = 'grade_points_finite_nonnegative'
        AND con.contype = 'c'
    ) THEN
        RAISE EXCEPTION 'data.grade must reject negative or non-finite points';
    END IF;

    IF pg_get_viewdef('api.assignment_grade_distributions'::regclass) NOT LIKE '%COALESCE(assignment_grade.points, (0)::real)%'
        OR pg_get_viewdef('api.assignment_grade_distributions'::regclass) NOT LIKE '%NOT assignment.is_draft%'
        OR pg_get_viewdef('api.assignment_grade_distributions'::regclass) NOT LIKE '%HAVING (count(*) >= 3)%'
    THEN
        RAISE EXCEPTION 'api.assignment_grade_distributions must include missing individual work as zero while suppressing cohorts smaller than three';
    END IF;

    IF pg_get_viewdef('api.quiz_grade_distributions'::regclass) NOT LIKE '%HAVING (count(quiz_grade.user_id) >= 3)%' THEN
        RAISE EXCEPTION 'api.quiz_grade_distributions must suppress cohorts smaller than three student grades';
    END IF;

    IF pg_get_viewdef('api.assignments'::regclass) NOT LIKE '%WHERE ((request.user_role() = ''faculty''::text) OR (is_draft = false))%'
    THEN
        RAISE EXCEPTION 'api.assignments must hide draft assignments from student and TA reads';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'api'
        AND c.relname = 'assignments'
        AND c.reloptions @> ARRAY['security_barrier=true']
    ) THEN
        RAISE EXCEPTION 'api.assignments must be a security barrier view';
    END IF;

    IF pg_get_viewdef('api.assignment_fields'::regclass) NOT LIKE '%request.user_role() = ''faculty''::text%'
        OR pg_get_viewdef('api.assignment_fields'::regclass) NOT LIKE '%assignment.is_draft = false%'
    THEN
        RAISE EXCEPTION 'api.assignment_fields must hide fields for draft assignments from student and TA reads';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'api'
        AND c.relname = 'assignment_fields'
        AND c.reloptions @> ARRAY['security_barrier=true']
    ) THEN
        RAISE EXCEPTION 'api.assignment_fields must be a security barrier view';
    END IF;

    IF pg_get_viewdef('api.quizzes'::regclass) NOT LIKE '%WHERE ((request.user_role() = ''faculty''::text) OR (is_draft = false))%'
    THEN
        RAISE EXCEPTION 'api.quizzes must hide draft quizzes from student and TA reads';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'api'
        AND c.relname = 'quizzes'
        AND c.reloptions @> ARRAY['security_barrier=true']
    ) THEN
        RAISE EXCEPTION 'api.quizzes must be a security barrier view';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_submission_participant'
        AND c.relkind = 'r'
    ) THEN
        RAISE EXCEPTION 'missing data.assignment_submission_participant table';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_submission_participant'
        AND con.contype = 'p'
        AND con.conkey = ARRAY[
            (
                SELECT attnum
                FROM pg_attribute
                WHERE attrelid = con.conrelid
                AND attname = 'assignment_submission_id'
            ),
            (
                SELECT attnum
                FROM pg_attribute
                WHERE attrelid = con.conrelid
                AND attname = 'user_id'
            )
        ]::smallint[]
    ) THEN
        RAISE EXCEPTION 'data.assignment_submission_participant must be keyed by assignment_submission_id and user_id';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_proc p ON p.oid = t.tgfoid
        JOIN pg_namespace pn ON pn.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment_submission'
        AND t.tgname = 'tg_assignment_submission_participants'
        AND (t.tgtype & 1) = 1
        AND (t.tgtype & 2) = 0
        AND (t.tgtype & 4) = 4
        AND (t.tgtype & 8) = 0
        AND (t.tgtype & 16) = 0
        AND pn.nspname = 'data'
        AND p.proname = 'refresh_assignment_submission_participants'
        AND NOT t.tgisinternal
    ) THEN
        RAISE EXCEPTION 'missing data.assignment_submission insert-only participant refresh trigger';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.proname = 'refresh_assignment_submission_participants'
        AND p.prosecdef
        AND p.proconfig @> ARRAY['search_path=data, pg_temp']
    ) THEN
        RAISE EXCEPTION 'data.refresh_assignment_submission_participants must be SECURITY DEFINER with pinned search_path';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.proname = 'fill_assignment_field_submission_defaults'
        AND p.prosecdef
        AND p.proconfig @> ARRAY['search_path=data, pg_temp']
    ) THEN
        RAISE EXCEPTION 'data.fill_assignment_field_submission_defaults must be SECURITY DEFINER with pinned search_path';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.proname = 'assignment_field_submission_is_writable_by_current_user'
        AND p.prosecdef
        AND p.proconfig @> ARRAY['search_path=data, pg_temp']
    ) THEN
        RAISE EXCEPTION 'data.assignment_field_submission_is_writable_by_current_user must be SECURITY DEFINER with pinned search_path';
    END IF;

    IF (
        SELECT count(*)
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.proname IN (
            'fill_assignment_grade_defaults',
            'fill_assignment_grade_exception_defaults',
            'fill_assignment_submission_defaults',
            'fill_quiz_grade_defaults',
            'quiz_set_defaults'
        )
        AND p.prosecdef
        AND p.proconfig @> ARRAY['search_path=data, pg_temp']
    ) <> 5 THEN
        RAISE EXCEPTION 'data lookup trigger functions must be SECURITY DEFINER with pinned search_path';
    END IF;

    IF NOT has_table_privilege('api', 'data.assignment_submission_participant', 'SELECT')
        OR NOT has_table_privilege('api', 'data.assignment_submission_participant', 'INSERT')
        OR NOT has_table_privilege('api', 'data.assignment_submission_participant', 'UPDATE')
        OR NOT has_table_privilege('api', 'data.assignment_submission_participant', 'DELETE')
    THEN
        RAISE EXCEPTION 'api must have table privileges on data.assignment_submission_participant';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'assignment'
        AND a.attname = 'is_team'
        AND a.attnotnull
    ) THEN
        RAISE EXCEPTION 'data.assignment.is_team is not NOT NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE n.nspname = 'data'
        AND c.relname = 'quiz'
        AND a.attname = 'is_offline'
        AND a.attnotnull
        AND pg_get_expr(d.adbin, d.adrelid) = 'true'
    ) THEN
        RAISE EXCEPTION 'data.quiz.is_offline must be NOT NULL DEFAULT true';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'quiz_answer'
    ) THEN
        RAISE EXCEPTION 'data.quiz_answer should not exist for paper-only quizzes';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'api'
        AND c.relname = 'platform_version'
        AND c.relkind = 'v'
    ) THEN
        RAISE EXCEPTION 'missing api.platform_version view';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM api.platform_version
        WHERE platform = 'yelukerest'
        AND platform_compatibility_version >= 1
        AND schema_compatibility_version >= 1
        AND admin_api_version >= 4
    ) THEN
        RAISE EXCEPTION 'invalid api.platform_version compatibility metadata';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api'
        AND p.proname = 'sync_meetings'
        AND pg_get_function_identity_arguments(p.oid) = 'p_meetings jsonb'
    ) THEN
        RAISE EXCEPTION 'missing api.sync_meetings(jsonb)';
    END IF;

    IF NOT has_function_privilege('faculty', 'api.sync_meetings(jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'faculty must be able to execute api.sync_meetings';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL unnest(p.proargnames, p.proargmodes) AS arg(argname, argmode)
        WHERE n.nspname = 'api'
        AND p.proname = 'sync_meetings'
        AND pg_get_function_identity_arguments(p.oid) = 'p_meetings jsonb'
        AND arg.argname = 'unchanged_count'
        AND arg.argmode = 't'
    ) THEN
        RAISE EXCEPTION 'api.sync_meetings must return unchanged_count';
    END IF;

    IF has_function_privilege('anonymous', 'api.sync_meetings(jsonb)', 'EXECUTE')
        OR has_function_privilege('student', 'api.sync_meetings(jsonb)', 'EXECUTE')
        OR has_function_privilege('ta', 'api.sync_meetings(jsonb)', 'EXECUTE')
        OR has_function_privilege('app', 'api.sync_meetings(jsonb)', 'EXECUTE')
    THEN
        RAISE EXCEPTION 'api.sync_meetings execute privilege is too broad';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api'
        AND p.proname = 'sync_assignments'
        AND pg_get_function_identity_arguments(p.oid) = 'p_assignments jsonb, p_delete_missing boolean, p_dry_run boolean'
    ) THEN
        RAISE EXCEPTION 'missing api.sync_assignments(jsonb, boolean, boolean)';
    END IF;

    IF NOT has_function_privilege('faculty', 'api.sync_assignments(jsonb, boolean, boolean)', 'EXECUTE') THEN
        RAISE EXCEPTION 'faculty must be able to execute api.sync_assignments';
    END IF;

    IF has_function_privilege('anonymous', 'api.sync_assignments(jsonb, boolean, boolean)', 'EXECUTE')
        OR has_function_privilege('student', 'api.sync_assignments(jsonb, boolean, boolean)', 'EXECUTE')
        OR has_function_privilege('ta', 'api.sync_assignments(jsonb, boolean, boolean)', 'EXECUTE')
        OR has_function_privilege('app', 'api.sync_assignments(jsonb, boolean, boolean)', 'EXECUTE')
    THEN
        RAISE EXCEPTION 'api.sync_assignments execute privilege is too broad';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'auth'
        AND p.proname = 'sign_jwt'
        AND p.proconfig @> ARRAY['search_path=pg_catalog, auth, settings, pgjwt, pg_temp']
    ) THEN
        RAISE EXCEPTION 'auth.sign_jwt search_path is not pinned';
    END IF;

    IF (
        SELECT count(*)
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE (n.nspname, p.proname) IN (
            ('auth', 'sign_jwt'),
            ('data', 'text_is_url'),
            ('data', 'text_matches'),
            ('request', 'app_name'),
            ('request', 'user_id'),
            ('request', 'user_id_as_text'),
            ('request', 'user_role'),
            ('settings', 'get'),
            ('settings', 'set')
        )
        AND p.prosqlbody IS NOT NULL
    ) <> 9 THEN
        RAISE EXCEPTION 'project-owned SQL helper functions must use parsed SQL bodies';
    END IF;

    IF to_regclass('api.quiz_submissions_info') IS NOT NULL THEN
        RAISE EXCEPTION 'api.quiz_submissions_info compatibility view must be removed';
    END IF;

    IF (
        SELECT count(*)
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE a.attidentity = 'd'
        AND (n.nspname, c.relname, a.attname) IN (
            ('data', 'artifact', 'id'),
            ('data', 'assignment_grade_exception', 'id'),
            ('data', 'assignment_submission', 'id'),
            ('data', 'quiz', 'id'),
            ('data', 'quiz_grade_exception', 'id'),
            ('data', 'todo', 'id'),
            ('data', 'user', 'id'),
            ('data', 'user_secret', 'id')
        )
    ) <> 8 THEN
        RAISE EXCEPTION 'surrogate id columns must use generated by default identity';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_attrdef d
        JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
        JOIN pg_class c ON c.oid = d.adrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%'
    ) THEN
        RAISE EXCEPTION 'data schema must not use serial-style nextval defaults';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_roles r
        CROSS JOIN pg_class s
        JOIN pg_namespace n ON n.oid = s.relnamespace
        WHERE r.rolname IN ('faculty', 'student', 'ta')
        AND n.nspname = 'data'
        AND s.relname IN ('assignment_submission_id_seq', 'quiz_id_seq')
        AND has_sequence_privilege(r.oid, s.oid, 'USAGE')
    ) THEN
        RAISE EXCEPTION 'api inserts must not depend on direct sequence usage grants';
    END IF;

    IF NOT has_function_privilege('api', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE') THEN
        RAISE EXCEPTION 'api must be able to execute auth.sign_jwt';
    END IF;

    IF NOT has_function_privilege('student', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE') THEN
        RAISE EXCEPTION 'student must be able to execute auth.sign_jwt through api.user_jwts';
    END IF;

    IF NOT has_function_privilege('ta', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE') THEN
        RAISE EXCEPTION 'ta must be able to execute auth.sign_jwt through api.user_jwts';
    END IF;

    IF NOT has_function_privilege('faculty', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE') THEN
        RAISE EXCEPTION 'faculty must be able to execute auth.sign_jwt through api.user_jwts';
    END IF;

    IF NOT has_function_privilege('app', 'auth.sign_jwt(integer, data.user_role)', 'EXECUTE') THEN
        RAISE EXCEPTION 'app must be able to execute auth.sign_jwt through api.user_jwts';
    END IF;

    IF has_schema_privilege('student', 'auth', 'USAGE') THEN
        RAISE EXCEPTION 'student must not have direct usage on auth schema';
    END IF;

    IF has_schema_privilege('ta', 'auth', 'USAGE') THEN
        RAISE EXCEPTION 'ta must not have direct usage on auth schema';
    END IF;

    IF has_schema_privilege('faculty', 'auth', 'USAGE') THEN
        RAISE EXCEPTION 'faculty must not have direct usage on auth schema';
    END IF;

    IF has_schema_privilege('app', 'auth', 'USAGE') THEN
        RAISE EXCEPTION 'app must not have direct usage on auth schema';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'settings'
        AND p.proname = 'get'
        AND p.proconfig @> ARRAY['search_path=pg_catalog, settings, pg_temp']
    ) THEN
        RAISE EXCEPTION 'settings.get search_path is not pinned';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE n.nspname = 'data'
        AND c.relname = 'user_secret'
        AND a.attname = 'is_user_visible'
        AND a.attnotnull
        AND pg_get_expr(d.adbin, d.adrelid) = 'true'
    ) THEN
        RAISE EXCEPTION 'data.user_secret.is_user_visible must be NOT NULL DEFAULT true';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'artifact'
        AND c.relkind = 'r'
    ) THEN
        RAISE EXCEPTION 'missing data.artifact table';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'api'
        AND c.relname = 'artifacts'
        AND c.relkind = 'v'
    ) THEN
        RAISE EXCEPTION 'missing api.artifacts view';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE n.nspname = 'data'
        AND c.relname = 'artifact'
        AND a.attname = 'is_user_visible'
        AND a.attnotnull
        AND pg_get_expr(d.adbin, d.adrelid) = 'true'
    ) THEN
        RAISE EXCEPTION 'data.artifact.is_user_visible must be NOT NULL DEFAULT true';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policy p
        JOIN pg_class c ON c.oid = p.polrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND c.relname = 'artifact'
        AND p.polname = 'artifact_access_policy'
    ) THEN
        RAISE EXCEPTION 'missing data.artifact RLS policy';
    END IF;

    IF NOT has_table_privilege('api', 'data.artifact', 'SELECT')
        OR NOT has_table_privilege('api', 'data.artifact', 'INSERT')
        OR NOT has_table_privilege('api', 'data.artifact', 'UPDATE')
        OR NOT has_table_privilege('api', 'data.artifact', 'DELETE')
    THEN
        RAISE EXCEPTION 'api must have table privileges on data.artifact';
    END IF;

    IF NOT has_table_privilege('student', 'api.artifacts', 'SELECT')
        OR NOT has_table_privilege('ta', 'api.artifacts', 'SELECT')
        OR NOT has_table_privilege('faculty', 'api.artifacts', 'SELECT')
        OR NOT has_table_privilege('faculty', 'api.artifacts', 'INSERT')
        OR NOT has_table_privilege('faculty', 'api.artifacts', 'UPDATE')
        OR NOT has_table_privilege('faculty', 'api.artifacts', 'DELETE')
    THEN
        RAISE EXCEPTION 'artifact API privileges are incomplete';
    END IF;

    IF EXISTS (
        WITH fk AS (
            SELECT
                c.oid,
                c.conrelid,
                c.conkey::int2[] AS conkey
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE c.contype = 'f'
            AND n.nspname = 'data'
        ),
        idx AS (
            SELECT
                ix.indrelid,
                string_to_array(ix.indkey::text, ' ')::int2[] AS indkey
            FROM pg_index ix
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_am am ON am.oid = i.relam
            WHERE ix.indisvalid
            AND ix.indisready
            AND ix.indpred IS NULL
            AND am.amname = 'btree'
        )
        SELECT 1
        FROM fk
        WHERE NOT EXISTS (
            SELECT 1
            FROM idx
            WHERE idx.indrelid = fk.conrelid
            AND idx.indkey[1:array_length(fk.conkey, 1)] = fk.conkey
        )
    ) THEN
        RAISE EXCEPTION 'every data foreign key must have a plain btree index on its referencing columns';
    END IF;
END $$;

ROLLBACK;
