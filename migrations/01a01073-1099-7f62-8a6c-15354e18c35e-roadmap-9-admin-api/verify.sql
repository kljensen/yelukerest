-- Verification for the Roadmap 9 admin API surface.
--
-- Runs after the migration commits, in a fresh READ ONLY transaction that is
-- always rolled back. No CREATE is possible here, not even a temp table, so
-- expected sets are built with VALUES.

DO $$
DECLARE
    missing text;
BEGIN
    -- The RPCs, by full signature: a function that lost an argument is a
    -- different contract, and course tooling preflights on admin_api_version
    -- expecting exactly these.
    SELECT string_agg(expected.sig, ', ' ORDER BY expected.sig) INTO missing
    FROM (VALUES
        ('api.import_assignment_grades(jsonb,boolean,boolean,text,text)'),
        ('api.import_quiz_results(jsonb,boolean,boolean,text,text)'),
        ('api.grant_assignment_extension(integer,text,timestamp with time zone,numeric)'),
        ('data.resolve_assignment_grade_import(jsonb)'),
        ('data.resolve_quiz_result_import(jsonb)'),
        ('data.grade_exception_credit_bounds(text)'),
        ('data.touched_at(timestamp with time zone,timestamp with time zone)')
    ) AS expected(sig)
    WHERE to_regprocedure(expected.sig) IS NULL;

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing admin API functions: %', missing;
    END IF;

    -- Faculty must be able to call them, or the surface exists but is unusable.
    SELECT string_agg(expected.sig, ', ' ORDER BY expected.sig) INTO missing
    FROM (VALUES
        ('api.import_assignment_grades(jsonb,boolean,boolean,text,text)'),
        ('api.import_quiz_results(jsonb,boolean,boolean,text,text)'),
        ('api.grant_assignment_extension(integer,text,timestamp with time zone,numeric)')
    ) AS expected(sig)
    WHERE NOT has_function_privilege('faculty', expected.sig, 'EXECUTE');

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'faculty cannot execute: %', missing;
    END IF;

    -- The insert-time participant snapshot. Deliberately in `data`, not `api`.
    IF to_regclass('data.team_submission_participation') IS NULL THEN
        RAISE EXCEPTION 'missing data.team_submission_participation';
    END IF;

    -- #308: every updated_at trigger clamps through data.touched_at rather than
    -- writing a bare current_timestamp, which is transaction start and can
    -- precede a row's created_at.
    IF (
        SELECT count(*) FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data' AND p.prosrc ~ 'data\.touched_at'
    ) <> 11 THEN
        RAISE EXCEPTION 'expected 11 updated_at triggers routed through data.touched_at';
    END IF;

    -- The online-quiz remnants are gone.
    IF to_regclass('data.quiz_grade_exception') IS NOT NULL THEN
        RAISE EXCEPTION 'data.quiz_grade_exception should have been dropped';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'data' AND table_name = 'quiz'
        AND column_name IN ('is_offline', 'duration')
    ) THEN
        RAISE EXCEPTION 'data.quiz should no longer carry is_offline or duration';
    END IF;

    -- Compatibility versions. A deployment that answers below these would let a
    -- client preflight successfully and then fail on its first request.
    IF NOT EXISTS (
        SELECT 1 FROM api.platform_version
        WHERE schema_compatibility_version = 4 AND admin_api_version = 8
    ) THEN
        RAISE EXCEPTION 'api.platform_version should report schema 4 and admin_api 8';
    END IF;
END $$;
