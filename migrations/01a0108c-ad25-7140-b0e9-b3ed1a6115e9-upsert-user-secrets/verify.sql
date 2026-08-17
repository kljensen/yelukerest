-- Verification for bulk secret distribution (#303).
--
-- Runs after the migration commits, in a fresh READ ONLY transaction that is
-- always rolled back. No CREATE is possible here, not even a temp table, so
-- expected sets are built with VALUES.

DO $$
DECLARE
    missing text;
    bounds record;
BEGIN
    -- By full signature: a function that lost an argument is a different
    -- contract, and course tooling preflights on admin_api_version expecting
    -- exactly these.
    SELECT string_agg(expected.sig, ', ' ORDER BY expected.sig) INTO missing
    FROM (VALUES
        ('api.upsert_user_secrets(jsonb,boolean)'),
        ('api.upsert_team_secrets(jsonb,boolean)'),
        ('data.check_user_secret_batch(jsonb,text,text)'),
        ('data.user_secret_input_bounds()')
    ) AS expected(sig)
    WHERE to_regprocedure(expected.sig) IS NULL;

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing secret distribution functions: %', missing;
    END IF;

    -- Faculty must be able to call them, or the surface exists but is unusable.
    SELECT string_agg(expected.sig, ', ' ORDER BY expected.sig) INTO missing
    FROM (VALUES
        ('api.upsert_user_secrets(jsonb,boolean)'),
        ('api.upsert_team_secrets(jsonb,boolean)')
    ) AS expected(sig)
    WHERE NOT has_function_privilege('faculty', expected.sig, 'EXECUTE');

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'faculty cannot execute: %', missing;
    END IF;

    -- And nobody else may. EXECUTE defaults to PUBLIC on a new function, so a
    -- REVOKE that was dropped from the migration would silently hand every
    -- student a bulk secret writer. Row-level security would still refuse the
    -- write, but the endpoint would be reachable, and it accepts a payload.
    SELECT string_agg(role_name.grantee || ' on ' || expected.sig, ', '
        ORDER BY role_name.grantee || ' on ' || expected.sig) INTO missing
    FROM (VALUES
        ('api.upsert_user_secrets(jsonb,boolean)'),
        ('api.upsert_team_secrets(jsonb,boolean)'),
        ('data.check_user_secret_batch(jsonb,text,text)'),
        ('data.user_secret_input_bounds()')
    ) AS expected(sig)
    CROSS JOIN (VALUES ('anonymous'), ('student'), ('ta'), ('observer')) AS role_name(grantee)
    WHERE has_function_privilege(role_name.grantee, expected.sig, 'EXECUTE');

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'secret distribution functions are executable by: %', missing;
    END IF;

    -- The arbiters the two ON CONFLICT clauses infer. Both are partial indexes,
    -- which is the whole reason this is an RPC rather than a POST to a view
    -- faculty already hold CRUD on: PostgREST's on_conflict cannot carry an
    -- index predicate. A dropped or reshaped predicate stops the inference.
    SELECT string_agg(expected.indexdef, ' | ' ORDER BY expected.indexdef) INTO missing
    FROM (VALUES
        ('CREATE UNIQUE INDEX secret_unique_slug_user ON data.user_secret USING btree (user_id, slug) WHERE (team_nickname IS NULL)'),
        ('CREATE UNIQUE INDEX secret_unique_slug_team ON data.user_secret USING btree (team_nickname, slug) WHERE (user_id IS NULL)')
    ) AS expected(indexdef)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'data'
        AND tablename = 'user_secret'
        AND pg_indexes.indexdef = expected.indexdef
    );

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'the user_secret upsert arbiters are not the expected partial unique indexes: %', missing;
    END IF;

    -- The bounds the pre-checks read. Every one has to resolve. A NULL here
    -- means a CHECK constraint was reshaped past the pattern
    -- data.user_secret_input_bounds matches, the pre-check would stop rejecting
    -- anything, and the constraint would fire at the write instead -- printing
    -- `DETAIL: Failing row contains (...)`, which on this table is a password.
    -- The functions refuse to run in that state; this catches it at deploy
    -- rather than at the first import.
    SELECT * INTO bounds FROM data.user_secret_input_bounds();

    IF bounds.body_octet_limit IS NULL
        OR bounds.slug_pattern IS NULL
        OR bounds.slug_length_limit IS NULL
        OR bounds.team_nickname_length_limit IS NULL
    THEN
        RAISE EXCEPTION 'data.user_secret_input_bounds cannot read every bound off the table constraints';
    END IF;

    -- #308, finished. data.fill_user_secret_defaults was the last trigger still
    -- assigning a bare current_timestamp, so the offending set is now empty.
    --
    -- An emptiness assertion rather than a count: it is exact, it needs no
    -- number to maintain, and unlike a count it stays true and stays meaningful
    -- as triggers are added. A count would have to be revised by every later
    -- migration, and revising it is how it stops being checked.
    SELECT string_agg(p.proname::text, ', ' ORDER BY p.proname::text) INTO missing
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'data'
    AND p.prosrc ~ 'NEW\.updated_at\s*:?=\s*current_timestamp';

    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'these triggers still assign current_timestamp directly: %', missing;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.proname = 'fill_user_secret_defaults'
        AND p.prosrc ~ 'NEW\.updated_at\s*:?=\s*data\.touched_at'
    ) THEN
        RAISE EXCEPTION 'data.fill_user_secret_defaults is not routed through data.touched_at';
    END IF;

    -- Compatibility versions. Two RPCs added and nothing removed, so
    -- admin_api_version reaches 9. A floor, not an equality: verification runs
    -- against the database as it is now, and `zapadka verify` re-runs every
    -- applied migration's script, so an equality would report a broken
    -- deployment every time a later migration added an RPC.
    --
    -- This deliberately says nothing about schema_compatibility_version. It
    -- once asserted `= 4`, which was the shape at the time and looked like the
    -- set-membership operator docs/platform-compatibility.md prescribes -- but
    -- the operator belongs to a *client* declaring the shapes it supports, not
    -- to a migration checking the database in front of it. Pinned here it made
    -- this script a veto on every future shape change, and add-assignment-
    -- repository (#312), which adds api.assignment_repositories and reaches
    -- shape 5, is the first one it vetoed. This migration changed no shape, so
    -- it has nothing to assert about one.
    IF NOT EXISTS (
        SELECT 1 FROM api.platform_version
        WHERE admin_api_version >= 9
    ) THEN
        RAISE EXCEPTION 'api.platform_version should report admin_api 9 or later';
    END IF;
END $$;
