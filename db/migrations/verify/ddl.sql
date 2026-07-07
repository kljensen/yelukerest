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
END $$;

ROLLBACK;
