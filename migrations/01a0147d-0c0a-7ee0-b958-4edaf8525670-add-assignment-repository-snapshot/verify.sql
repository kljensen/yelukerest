-- Verification for the deadline snapshots of student repositories (#22).
--
-- Runs after the migration commits, in a fresh READ ONLY transaction that is
-- always rolled back. No CREATE is possible here, not even a temp table, so
-- expected sets are built with VALUES.

DO $$
DECLARE
    missing text;
    policy_using text;
    policy_check text;
BEGIN
    -- The table and the two views it is served through.
    IF to_regclass('data.assignment_repository_snapshot') IS NULL THEN
        RAISE EXCEPTION 'missing data.assignment_repository_snapshot';
    END IF;

    IF to_regclass('api.assignment_repository_snapshots') IS NULL THEN
        RAISE EXCEPTION 'missing api.assignment_repository_snapshots';
    END IF;

    IF to_regclass('api.assignment_repository_snapshots_due') IS NULL THEN
        RAISE EXCEPTION 'missing api.assignment_repository_snapshots_due';
    END IF;

    -- Owned by `api`, or the row-level security policy below never applies to
    -- anything read through the view and every student sees every row.
    SELECT string_agg(expected.viewname, ', ' ORDER BY expected.viewname) INTO missing
    FROM (VALUES
        ('assignment_repository_snapshots'),
        ('assignment_repository_snapshots_due')
    ) AS expected(viewname)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_views
        WHERE schemaname = 'api'
        AND pg_views.viewname = expected.viewname
        AND viewowner = 'api'
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'these api snapshot views are not owned by the api role: %', missing;
    END IF;

    -- Every column is required. A capture that could not be completed writes no
    -- row at all, so there is no half-filled row to represent.
    SELECT string_agg(expected.column_name, ', ' ORDER BY expected.column_name) INTO missing
    FROM (VALUES
        ('assignment_repository_id', 'integer'),
        ('effective_closed_at', 'timestamp with time zone'),
        ('captured_at', 'timestamp with time zone'),
        ('commit_sha', 'text'),
        ('bundle_uri', 'text')
    ) AS expected(column_name, data_type)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns AS c
        WHERE c.table_schema = 'data'
        AND c.table_name = 'assignment_repository_snapshot'
        AND c.column_name = expected.column_name
        AND c.data_type = expected.data_type
        AND c.is_nullable = 'NO'
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION
            'data.assignment_repository_snapshot is missing these NOT NULL columns, or they have the wrong type: %',
            missing;
    END IF;

    -- One snapshot per repository per deadline. This is what makes a failed
    -- capture retry (no row, so still due) and an extension re-capture (new
    -- deadline, so a new row) both work without any reconciliation step.
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'assignment_repository_snapshot_per_deadline'
        AND conrelid = 'data.assignment_repository_snapshot'::regclass
        AND contype = 'u'
    ) THEN
        RAISE EXCEPTION 'missing the unique constraint on (assignment_repository_id, effective_closed_at)';
    END IF;

    -- Row-level security enabled, or the policy below is inert and every
    -- student reads every other student's snapshots.
    IF NOT EXISTS (
        SELECT 1 FROM pg_class
        WHERE oid = 'data.assignment_repository_snapshot'::regclass
        AND relrowsecurity
    ) THEN
        RAISE EXCEPTION 'row-level security is not enabled on data.assignment_repository_snapshot';
    END IF;

    SELECT pg_get_expr(polqual, polrelid), pg_get_expr(polwithcheck, polrelid)
    INTO policy_using, policy_check
    FROM pg_policy
    WHERE polrelid = 'data.assignment_repository_snapshot'::regclass
    AND polname = 'assignment_repository_snapshot_access_policy';

    IF policy_using IS NULL THEN
        RAISE EXCEPTION 'missing assignment_repository_snapshot_access_policy';
    END IF;

    -- Reads resolve ownership through the repository, so the live-team rule is
    -- not restated here and cannot drift from it.
    IF policy_using NOT LIKE '%assignment_repository%' THEN
        RAISE EXCEPTION
            'the snapshot read policy does not resolve ownership through data.assignment_repository: %',
            policy_using;
    END IF;

    -- Writes are faculty-only. A student who could write here could nominate a
    -- different artifact as the graded one, which is the property this table
    -- exists to establish.
    IF policy_check IS NULL OR policy_check LIKE '%student%' THEN
        RAISE EXCEPTION 'the snapshot write check is not faculty-only: %', COALESCE(policy_check, '<null>');
    END IF;

    -- The queue carries other students' deadlines and nobody but the runner
    -- reads it.
    IF has_table_privilege('student', 'api.assignment_repository_snapshots_due', 'SELECT') THEN
        RAISE EXCEPTION 'student can read the snapshot work queue';
    END IF;

    IF NOT has_table_privilege('faculty', 'api.assignment_repository_snapshots_due', 'SELECT') THEN
        RAISE EXCEPTION 'faculty cannot read the snapshot work queue';
    END IF;

    -- Students read their own snapshots, which is the regrade support path.
    IF NOT has_table_privilege('student', 'api.assignment_repository_snapshots', 'SELECT') THEN
        RAISE EXCEPTION 'student cannot read api.assignment_repository_snapshots';
    END IF;

    IF has_table_privilege('student', 'api.assignment_repository_snapshots', 'INSERT') THEN
        RAISE EXCEPTION 'student can write api.assignment_repository_snapshots';
    END IF;

    -- The api schema gained two views, so the shape reaches 6 here.
    --
    -- Asserted as a floor, not an equality. verify runs against the deployed
    -- state as a whole, not against a snapshot taken the day this migration
    -- landed, so any later migration that adds an api view makes an equality
    -- check here false -- which is exactly what happened when the personal
    -- access token migration moved the shape to 7 and this went red on every
    -- commit for four days. The exact current value is asserted once, in
    -- tests/rest/yeluke/platform_version.js, where a single test is updated
    -- with each bump.
    IF NOT EXISTS (
        SELECT 1 FROM api.platform_version
        WHERE schema_compatibility_version >= 6
        AND admin_api_version >= 9
    ) THEN
        RAISE EXCEPTION 'api.platform_version does not report schema shape 6 and admin api 9';
    END IF;
END
$$;
