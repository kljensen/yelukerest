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
        AND admin_api_version >= 1
    ) THEN
        RAISE EXCEPTION 'invalid api.platform_version compatibility metadata';
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
