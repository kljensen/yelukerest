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

    -- The recorded artifact, and the nullability that makes a failed capture
    -- representable. A NOT NULL commit_sha would mean a failure could not be
    -- written down at all, which is the state this table exists to make
    -- visible.
    SELECT string_agg(expected.column_name || ' ' || expected.data_type, ', '
        ORDER BY expected.column_name) INTO missing
    FROM (VALUES
        ('assignment_repository_id', 'integer', true),
        ('effective_closed_at', 'timestamp with time zone', true),
        ('captured_at', 'timestamp with time zone', true),
        ('commit_sha', 'text', false),
        ('bundle_uri', 'text', false),
        ('bundle_sha256', 'text', false),
        ('is_verified', 'boolean', true),
        ('error', 'text', false),
        ('superseded_at', 'timestamp with time zone', false)
    ) AS expected(column_name, data_type, is_required)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'data'
        AND table_name = 'assignment_repository_snapshot'
        AND columns.column_name = expected.column_name
        AND columns.data_type = expected.data_type
        AND (columns.is_nullable = 'NO') = expected.is_required
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'data.assignment_repository_snapshot columns are not as declared: %', missing;
    END IF;

    -- The digest and commit-SHA shapes, the capture-after-deadline invariant,
    -- and the completeness rule. Compared as the definition PostgreSQL renders,
    -- because a CHECK loosened to accept uppercase hex, a truncated digest, or a
    -- verified row with no bundle is still a CHECK with the right name.
    SELECT string_agg(expected.conname, ', ' ORDER BY expected.conname) INTO missing
    FROM (VALUES
        ('assignment_repository_snapshot_commit_sha_check',
         'CHECK (((commit_sha ~ ''^[0-9a-f]{40}$''::text) OR (commit_sha ~ ''^[0-9a-f]{64}$''::text)))'),
        ('assignment_repository_snapshot_bundle_sha256_check',
         'CHECK ((bundle_sha256 ~ ''^[0-9a-f]{64}$''::text))'),
        ('captured_after_deadline',
         'CHECK ((captured_at >= effective_closed_at))'),
        ('superseded_after_captured',
         'CHECK (((superseded_at IS NULL) OR (superseded_at >= captured_at)))'),
        ('updated_after_created',
         'CHECK ((updated_at >= created_at))'),
        ('verified_snapshot_is_complete',
         'CHECK (((is_verified AND (commit_sha IS NOT NULL) AND (bundle_uri IS NOT NULL) AND (bundle_sha256 IS NOT NULL) AND (error IS NULL)) OR ((NOT is_verified) AND (error IS NOT NULL))))')
    ) AS expected(conname, condef)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'data.assignment_repository_snapshot'::regclass
        AND pg_constraint.conname = expected.conname
        AND pg_get_constraintdef(pg_constraint.oid) = expected.condef
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'data.assignment_repository_snapshot constraints are missing or reshaped: %', missing;
    END IF;

    -- At most one current, verified snapshot per repository. The predicate is
    -- the whole constraint: without `is_verified` a single failure would block
    -- every retry from being recorded, and without `superseded_at IS NULL` a
    -- capture for a moved deadline could never be written at all.
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'data'
        AND tablename = 'assignment_repository_snapshot'
        AND indexdef = 'CREATE UNIQUE INDEX assignment_repository_snapshot_current ON data.assignment_repository_snapshot USING btree (assignment_repository_id) WHERE (is_verified AND (superseded_at IS NULL))'
    ) THEN
        RAISE EXCEPTION 'the current-snapshot rule is not the expected partial unique index';
    END IF;

    -- Every foreign key backed by a plain btree index whose leading columns are
    -- the constraint's referencing columns, in the constraint's own order. The
    -- partial unique index above cannot serve a referential integrity check,
    -- which is why tests/db/foreign-key-indexes.sql ignores indexes carrying a
    -- predicate -- and why this repeats the rule for this table at deploy time.
    SELECT string_agg(fk.conname, ', ' ORDER BY fk.conname) INTO missing
    FROM pg_constraint fk
    WHERE fk.conrelid = 'data.assignment_repository_snapshot'::regclass
    AND fk.contype = 'f'
    AND NOT EXISTS (
        SELECT 1
        FROM pg_index ix
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_am am ON am.oid = i.relam
        WHERE ix.indrelid = fk.conrelid
        AND ix.indisvalid
        AND ix.indisready
        AND ix.indpred IS NULL
        AND am.amname = 'btree'
        AND (string_to_array(ix.indkey::text, ' ')::int2[])[1:array_length(fk.conkey, 1)]
            = fk.conkey::int2[]
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'these snapshot foreign keys have no plain btree index: %', missing;
    END IF;

    -- Row-level security, on and policed.
    IF NOT EXISTS (
        SELECT 1 FROM pg_class
        WHERE oid = 'data.assignment_repository_snapshot'::regclass
        AND relrowsecurity
    ) THEN
        RAISE EXCEPTION 'data.assignment_repository_snapshot does not have row level security enabled';
    END IF;

    SELECT pg_get_expr(pol.polqual, pol.polrelid),
           pg_get_expr(pol.polwithcheck, pol.polrelid)
    INTO policy_using, policy_check
    FROM pg_policy pol
    WHERE pol.polrelid = 'data.assignment_repository_snapshot'::regclass
    AND pol.polname = 'assignment_repository_snapshot_access_policy';

    IF policy_using IS NULL THEN
        RAISE EXCEPTION 'missing assignment_repository_snapshot_access_policy on data.assignment_repository_snapshot';
    END IF;

    -- A read policy that stopped consulting request.user_id() is a policy that
    -- shows one student which commit another student handed in. Asserted on the
    -- rendered expression rather than on behavior, because verification cannot
    -- switch role: it runs read-only in one transaction as the migrator.
    -- tests/db/yeluke-assignment-repository-snapshot.sql makes the behavioral
    -- assertion.
    IF policy_using !~ 'request\.user_id\(\)' THEN
        RAISE EXCEPTION 'the snapshot read policy does not restrict students by user: %', policy_using;
    END IF;

    -- Writes are faculty-only. A WITH CHECK that grew a student branch would let
    -- a student nominate a different artifact as the one that was graded, which
    -- is exactly the property this table exists to establish.
    IF policy_check IS NULL OR policy_check !~ '''faculty''' OR policy_check ~ 'student' THEN
        RAISE EXCEPTION 'the snapshot write policy is not faculty-only: %', policy_check;
    END IF;

    -- Privileges. The api role holds the table; faculty write snapshots and read
    -- the queue; students and TAs read snapshots only, and hold nothing on the
    -- base table or on the queue.
    SELECT string_agg(expected.grantee || ' ' || expected.privilege
        || ' on ' || expected.relation, ', '
        ORDER BY expected.grantee || expected.privilege || expected.relation) INTO missing
    FROM (VALUES
        ('api', 'data.assignment_repository_snapshot', 'SELECT'),
        ('api', 'data.assignment_repository_snapshot', 'INSERT'),
        ('api', 'data.assignment_repository_snapshot', 'UPDATE'),
        ('api', 'data.assignment_repository_snapshot', 'DELETE'),
        ('faculty', 'api.assignment_repository_snapshots', 'SELECT'),
        ('faculty', 'api.assignment_repository_snapshots', 'INSERT'),
        ('faculty', 'api.assignment_repository_snapshots', 'UPDATE'),
        ('faculty', 'api.assignment_repository_snapshots', 'DELETE'),
        ('faculty', 'api.assignment_repository_snapshots_due', 'SELECT'),
        ('student', 'api.assignment_repository_snapshots', 'SELECT'),
        ('ta', 'api.assignment_repository_snapshots', 'SELECT')
    ) AS expected(grantee, relation, privilege)
    WHERE NOT has_table_privilege(expected.grantee, expected.relation, expected.privilege);

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing snapshot privileges: %', missing;
    END IF;

    -- And nothing beyond that. A student holding INSERT on the snapshot view, or
    -- any privilege at all on the base table, escapes the policy's WITH CHECK
    -- for the base-table case; a student holding SELECT on the queue reads every
    -- other student's effective deadline.
    SELECT string_agg(role_name.grantee || ' ' || privilege.name
        || ' on ' || relation.name, ', '
        ORDER BY role_name.grantee || privilege.name || relation.name) INTO missing
    FROM (VALUES ('anonymous'), ('observer'), ('student'), ('ta')) AS role_name(grantee)
    CROSS JOIN (VALUES
        ('data.assignment_repository_snapshot'),
        ('api.assignment_repository_snapshots'),
        ('api.assignment_repository_snapshots_due')
    ) AS relation(name)
    CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS privilege(name)
    WHERE has_table_privilege(role_name.grantee, relation.name, privilege.name)
    AND NOT (
        relation.name = 'api.assignment_repository_snapshots'
        AND privilege.name = 'SELECT'
        AND role_name.grantee IN ('student', 'ta')
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'unexpected snapshot privileges: %', missing;
    END IF;

    -- The updated_at trigger, so an edited snapshot cannot keep claiming it was
    -- last touched when it was captured.
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'data.assignment_repository_snapshot'::regclass
        AND tgname = 'tg_assignment_repository_snapshot_update_timestamps'
        AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION 'data.assignment_repository_snapshot has no updated_at trigger';
    END IF;

    -- Compatibility versions. The api schema gained two views, so the shape
    -- moved past 5; no RPC was added, so admin_api_version stays where it was.
    --
    -- A floor rather than `= 6`, deliberately. Set membership is the operator a
    -- *client* uses to declare which shapes it supports; a migration cannot pin
    -- the shape it minted, because `zapadka verify` re-runs this script against
    -- head and every later shape change would make an equality false. What is
    -- durable here is that the deployment no longer advertises a shape that
    -- predates these views -- and their existence, asserted at the top of this
    -- script, is what stops a later removal from sliding under the floor.
    -- See docs/platform-compatibility.md.
    IF NOT EXISTS (
        SELECT 1 FROM api.platform_version
        WHERE schema_compatibility_version >= 6 AND admin_api_version >= 9
    ) THEN
        RAISE EXCEPTION 'api.platform_version should report schema 6 or later and admin_api 9 or later';
    END IF;
END $$;
