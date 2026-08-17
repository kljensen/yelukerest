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
    --
    -- Named rather than counted. This was written as `count(*) = 11`, which was
    -- true at the moment this migration shipped and false as soon as
    -- upsert-user-secrets converted data.fill_user_secret_defaults, the one
    -- holdout -- and a count cannot be repaired by moving it to 12 either,
    -- because verification runs twice in two different worlds: once during
    -- `deploy`, immediately after this migration applies and before any later
    -- one has, and again during `verify` against head. Only 11 exist in the
    -- first world and 12 in the second, so no number is right in both. The set
    -- this migration is actually responsible for does not move.
    SELECT string_agg(expected.proname, ', ' ORDER BY expected.proname) INTO missing
    FROM (VALUES
        ('update_updated_at_column'),
        ('fill_assignment_field_submission_defaults'),
        ('fill_assignment_grade_defaults'),
        ('fill_assignment_grade_exception_defaults'),
        ('fill_assignment_submission_defaults'),
        ('fill_grade_defaults'),
        ('fill_grade_snapshot_defaults'),
        ('fill_quiz_grade_defaults'),
        ('fill_quiz_submission_defaults'),
        ('quiz_set_defaults'),
        ('clean_user_fields')
    ) AS expected(proname)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.proname = expected.proname
        AND p.prosrc ~ 'NEW\.updated_at\s*:?=\s*data\.touched_at'
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'these updated_at triggers are not routed through data.touched_at: %', missing;
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
    --
    -- Checked with the operators the two versions actually take, because
    -- verification always runs against the database as it is now rather than as
    -- it was at this point in the graph. `admin_api_version` only ever grows,
    -- each bump adding an RPC without removing one, so a floor is exactly the
    -- assertion this migration wants: everything it introduced is still there
    -- at 9 or 10. It was written as `= 8` and became false the moment
    -- upsert-user-secrets shipped 9, which is a wrong operator rather than a
    -- broken schema.
    --
    -- `schema_compatibility_version` was pinned here as `= 4` for the same
    -- reason, and it was the same mistake one step later. Set membership is the
    -- operator a *client* uses to declare the shapes it supports; it is not an
    -- assertion a migration can make about the database in front of it, because
    -- every later shape change makes it false. add-assignment-repository (#312)
    -- reaches shape 5, and this migration's shape claims -- the dropped view and
    -- the two dropped quiz columns -- are already checked above by name, where
    -- they mean something. See docs/platform-compatibility.md.
    IF NOT EXISTS (
        SELECT 1 FROM api.platform_version
        WHERE admin_api_version >= 8
    ) THEN
        RAISE EXCEPTION 'api.platform_version should report admin_api 8 or later';
    END IF;
END $$;
