-- Verification for the assignment repository mapping (#312).
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
    -- The table and the view it is served through.
    IF to_regclass('data.assignment_repository') IS NULL THEN
        RAISE EXCEPTION 'missing data.assignment_repository';
    END IF;

    IF to_regclass('api.assignment_repositories') IS NULL THEN
        RAISE EXCEPTION 'missing api.assignment_repositories';
    END IF;

    -- Owned by `api`, or the row-level security policy below never applies to
    -- anything read through the view and every student sees every row.
    IF NOT EXISTS (
        SELECT 1 FROM pg_views
        WHERE schemaname = 'api'
        AND viewname = 'assignment_repositories'
        AND viewowner = 'api'
    ) THEN
        RAISE EXCEPTION 'api.assignment_repositories is not owned by the api role';
    END IF;

    -- Identity has to be an id, and it has to be required. A nullable or
    -- renamed provider_repo_id turns the record back into something derived
    -- from a repository name, which is the pattern this table exists to end.
    SELECT string_agg(expected.column_name || ' ' || expected.data_type, ', '
        ORDER BY expected.column_name) INTO missing
    FROM (VALUES
        ('provider', 'text', true),
        ('provider_repo_id', 'bigint', true),
        ('provider_full_name', 'text', true),
        ('provider_user_id', 'bigint', false),
        ('assignment_slug', 'text', true),
        ('is_team', 'boolean', true)
    ) AS expected(column_name, data_type, is_required)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'data'
        AND table_name = 'assignment_repository'
        AND columns.column_name = expected.column_name
        AND columns.data_type = expected.data_type
        AND (columns.is_nullable = 'NO') = expected.is_required
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'data.assignment_repository columns are not as declared: %', missing;
    END IF;

    -- Exactly one of user_id / team_nickname, agreeing with the assignment's own
    -- kind. Compared as the definition PostgreSQL renders, so a constraint
    -- loosened to admit both, or neither, is caught rather than merely counted.
    SELECT string_agg(expected.conname || ': ' || expected.condef, ' | '
        ORDER BY expected.conname) INTO missing
    FROM (VALUES
        ('matches_assignment_is_team',
         'CHECK (((is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((NOT is_team) AND (team_nickname IS NULL) AND (user_id IS NOT NULL))))'),
        ('updated_after_created',
         'CHECK ((updated_at >= created_at))'),
        ('assignment_repository_unique_provider_repo',
         'UNIQUE (provider, provider_repo_id)')
    ) AS expected(conname, condef)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'data.assignment_repository'::regclass
        AND pg_constraint.conname = expected.conname
        AND pg_get_constraintdef(pg_constraint.oid) = expected.condef
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'data.assignment_repository constraints are missing or reshaped: %', missing;
    END IF;

    -- One repository per student per assignment, and per team per assignment.
    -- The predicates are load-bearing: NULLs are distinct in a unique index, so
    -- an index that lost its `WHERE` admits every team row unchecked.
    SELECT string_agg(expected.indexdef, ' | ' ORDER BY expected.indexdef) INTO missing
    FROM (VALUES
        ('CREATE UNIQUE INDEX assignment_repository_unique_user ON data.assignment_repository USING btree (user_id, assignment_slug) WHERE (team_nickname IS NULL)'),
        ('CREATE UNIQUE INDEX assignment_repository_unique_team ON data.assignment_repository USING btree (team_nickname, assignment_slug) WHERE (user_id IS NULL)')
    ) AS expected(indexdef)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'data'
        AND tablename = 'assignment_repository'
        AND pg_indexes.indexdef = expected.indexdef
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'the assignment repository uniqueness rules are not the expected partial unique indexes: %', missing;
    END IF;

    -- Every foreign key backed by a plain btree index on its referencing
    -- columns, in the constraint's own column order. The partial unique indexes
    -- above cannot serve a referential integrity check, which is why
    -- tests/db/foreign-key-indexes.sql ignores indexes carrying a predicate --
    -- and why this repeats the rule for this table at deploy time.
    SELECT string_agg(fk.conname, ', ' ORDER BY fk.conname) INTO missing
    FROM pg_constraint fk
    WHERE fk.conrelid = 'data.assignment_repository'::regclass
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
        RAISE EXCEPTION 'these assignment repository foreign keys have no plain btree index: %', missing;
    END IF;

    -- Row-level security, on and policed.
    IF NOT EXISTS (
        SELECT 1 FROM pg_class
        WHERE oid = 'data.assignment_repository'::regclass
        AND relrowsecurity
    ) THEN
        RAISE EXCEPTION 'data.assignment_repository does not have row level security enabled';
    END IF;

    SELECT pg_get_expr(pol.polqual, pol.polrelid),
           pg_get_expr(pol.polwithcheck, pol.polrelid)
    INTO policy_using, policy_check
    FROM pg_policy pol
    WHERE pol.polrelid = 'data.assignment_repository'::regclass
    AND pol.polname = 'assignment_repository_access_policy';

    IF policy_using IS NULL THEN
        RAISE EXCEPTION 'missing assignment_repository_access_policy on data.assignment_repository';
    END IF;

    -- A read policy that stopped consulting request.user_id() is a policy that
    -- shows one student another student's repository. Asserted on the rendered
    -- expression rather than on behavior, because verification cannot switch
    -- role: it runs read-only in one transaction as the migrator.
    -- tests/db/yeluke-assignment-repository.sql makes the behavioral assertion.
    IF policy_using !~ 'request\.user_id\(\)' THEN
        RAISE EXCEPTION 'the assignment repository read policy does not restrict students by user: %', policy_using;
    END IF;

    -- Writes are faculty-only, and the WITH CHECK is where that is enforced for
    -- anything reaching the table through the api role. A WITH CHECK that grew
    -- a student branch would let a student point an assignment at a repository
    -- of their choosing after the deadline.
    IF policy_check IS NULL OR policy_check !~ '''faculty''' OR policy_check ~ 'student' THEN
        RAISE EXCEPTION 'the assignment repository write policy is not faculty-only: %', policy_check;
    END IF;

    -- Privileges. The api role holds the table; faculty write through the view;
    -- students and TAs read through it and hold nothing on the base table.
    SELECT string_agg(expected.grantee || ' ' || expected.privilege
        || ' on ' || expected.relation, ', '
        ORDER BY expected.grantee || expected.privilege || expected.relation) INTO missing
    FROM (VALUES
        ('api', 'data.assignment_repository', 'SELECT'),
        ('api', 'data.assignment_repository', 'INSERT'),
        ('api', 'data.assignment_repository', 'UPDATE'),
        ('api', 'data.assignment_repository', 'DELETE'),
        ('faculty', 'api.assignment_repositories', 'SELECT'),
        ('faculty', 'api.assignment_repositories', 'INSERT'),
        ('faculty', 'api.assignment_repositories', 'UPDATE'),
        ('faculty', 'api.assignment_repositories', 'DELETE'),
        ('student', 'api.assignment_repositories', 'SELECT'),
        ('ta', 'api.assignment_repositories', 'SELECT')
    ) AS expected(grantee, relation, privilege)
    WHERE NOT has_table_privilege(expected.grantee, expected.relation, expected.privilege);

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing assignment repository privileges: %', missing;
    END IF;

    -- And nothing beyond that. A student holding INSERT on the view, or any
    -- privilege at all on the base table, escapes the policy's WITH CHECK for
    -- the base-table case and makes the read policy the only thing standing
    -- between a student and another student's repository record.
    SELECT string_agg(role_name.grantee || ' ' || privilege.name
        || ' on ' || relation.name, ', '
        ORDER BY role_name.grantee || privilege.name || relation.name) INTO missing
    FROM (VALUES ('anonymous'), ('observer'), ('student'), ('ta')) AS role_name(grantee)
    CROSS JOIN (VALUES ('data.assignment_repository'), ('api.assignment_repositories')) AS relation(name)
    CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS privilege(name)
    WHERE has_table_privilege(role_name.grantee, relation.name, privilege.name)
    AND NOT (
        relation.name = 'api.assignment_repositories'
        AND privilege.name = 'SELECT'
        AND role_name.grantee IN ('student', 'ta')
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'unexpected assignment repository privileges: %', missing;
    END IF;

    -- The updated_at trigger, so a changed row cannot keep claiming it was last
    -- touched when it was provisioned.
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'data.assignment_repository'::regclass
        AND tgname = 'tg_assignment_repository_update_timestamps'
        AND NOT tgisinternal
    ) THEN
        RAISE EXCEPTION 'data.assignment_repository has no updated_at trigger';
    END IF;

    -- Compatibility versions. The api schema gained a view, so the shape moved
    -- past 4; no RPC was added, so admin_api_version stays where it was.
    --
    -- A floor rather than `= 5`, and the distinction matters. Set membership is
    -- the operator a *client* uses to declare which shapes it supports; a
    -- migration cannot pin the shape it minted, because `zapadka verify`
    -- re-runs this script against head and every later shape change would make
    -- an equality false. That is exactly how the equalities in roadmap-9-admin-
    -- api and upsert-user-secrets came to veto this migration. What is durable
    -- here is that the deployment no longer advertises a shape that predates
    -- api.assignment_repositories -- and the view's own existence, asserted at
    -- the top of this script, is what stops a later removal from sliding under
    -- the floor. See docs/platform-compatibility.md.
    IF NOT EXISTS (
        SELECT 1 FROM api.platform_version
        WHERE schema_compatibility_version >= 5 AND admin_api_version >= 9
    ) THEN
        RAISE EXCEPTION 'api.platform_version should report schema 5 or later and admin_api 9 or later';
    END IF;
END $$;
