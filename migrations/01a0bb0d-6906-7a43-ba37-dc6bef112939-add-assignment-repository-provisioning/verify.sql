-- Verification for repository templates and provisioning (#394).
--
-- Runs after the migration commits, in a fresh READ ONLY transaction that is
-- always rolled back. Structure and privileges only; behaviour is asserted in
-- tests/db/yeluke-repository_provisioning.sql, where a failure names the
-- case. Nothing here pins the exact shape of a view or the exact platform
-- version: later migrations extend both, and `zapadka verify` runs this
-- script against head.
DO $$
DECLARE
    missing text;
BEGIN
    SELECT string_agg(expected.relation, ', ' ORDER BY expected.relation) INTO missing
    FROM (VALUES
        ('data.repository_template'),
        ('data.assignment_repository_provisioning'),
        ('api.repository_templates'),
        ('api.repository_provisionings'),
        ('api.my_repositories')
    ) AS expected(relation)
    WHERE to_regclass(expected.relation) IS NULL;
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing relations: %', missing;
    END IF;

    -- Every view the migration touched has to be owned by api, or the row
    -- policies stop applying to what is read through it.
    SELECT string_agg(viewname, ', ' ORDER BY viewname) INTO missing
    FROM pg_views
    WHERE schemaname = 'api'
      AND viewname IN ('repository_templates', 'repository_provisionings', 'my_repositories', 'assignment_repositories', 'users')
      AND viewowner <> 'api';
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'api views not owned by api: %', missing;
    END IF;

    -- The columns, on the tables and on the views that expose them.
    SELECT string_agg(expected.relation || '.' || expected.column_name, ', '
        ORDER BY expected.relation || '.' || expected.column_name) INTO missing
    FROM (VALUES
        ('data', 'user', 'github_user_id'),
        ('data', 'user', 'github_login'),
        ('data', 'user', 'github_verified_at'),
        ('data', 'assignment_repository', 'template_slug'),
        ('data', 'assignment_repository_provisioning', 'template_slug'),
        ('api', 'assignment_repositories', 'template_slug'),
        ('api', 'my_repositories', 'repo_url'),
        ('api', 'users', 'github_user_id'),
        ('api', 'users', 'github_login'),
        ('api', 'users', 'github_verified_at')
    ) AS expected(schema_name, relation, column_name)
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = expected.schema_name
          AND c.table_name = expected.relation
          AND c.column_name = expected.column_name
    );
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing columns: %', missing;
    END IF;

    -- The template columns that left data.assignment must be gone, and the
    -- attempt table must not carry an assignment of its own.
    SELECT string_agg(c.table_name || '.' || c.column_name, ', ' ORDER BY c.table_name || '.' || c.column_name) INTO missing
    FROM information_schema.columns c
    WHERE c.table_schema = 'data'
      AND ((c.table_name = 'assignment' AND c.column_name IN ('repository_template_provider', 'repository_template_full_name', 'repository_url_field_slug'))
        OR (c.table_name = 'assignment_repository_provisioning' AND c.column_name = 'assignment_slug'));
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'columns that should not exist: %', missing;
    END IF;

    -- assignment_slug is optional on a repository now; template_slug is not.
    SELECT string_agg(c.column_name || ' is_nullable=' || c.is_nullable, ', ' ORDER BY c.column_name) INTO missing
    FROM information_schema.columns c
    WHERE c.table_schema = 'data' AND c.table_name = 'assignment_repository'
      AND ((c.column_name = 'assignment_slug' AND c.is_nullable = 'NO')
        OR (c.column_name = 'template_slug' AND c.is_nullable = 'YES'));
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'wrong nullability on data.assignment_repository: %', missing;
    END IF;

    -- The constraints that carry the contract: the owner XOR, generated
    -- knows its repository, and the composite keys onto the template and
    -- the assignment that make a team repository from an individual
    -- template, or a team template on an individual assignment,
    -- unrepresentable.
    SELECT string_agg(expected.conname, ', ' ORDER BY expected.conname) INTO missing
    FROM (VALUES
        ('data.assignment_repository_provisioning'::regclass, 'matches_template_is_team'),
        ('data.assignment_repository_provisioning'::regclass, 'generated_knows_repository'),
        ('data.assignment_repository'::regclass, 'matches_assignment_is_team')
    ) AS expected(conrelid, conname)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        WHERE c.conrelid = expected.conrelid AND c.conname = expected.conname
    );
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing constraints: %', missing;
    END IF;

    SELECT string_agg(expected.conrelid::text || ' -> ' || expected.confrelid::text || ' (' || expected.columns || ')', ', ') INTO missing
    FROM (VALUES
        ('data.repository_template'::regclass, 'data.assignment'::regclass, 'assignment_slug, is_team'),
        ('data.assignment_repository'::regclass, 'data.repository_template'::regclass, 'template_slug, is_team'),
        ('data.assignment_repository'::regclass, 'data.assignment'::regclass, 'assignment_slug, is_team'),
        ('data.assignment_repository_provisioning'::regclass, 'data.repository_template'::regclass, 'template_slug, is_team')
    ) AS expected(conrelid, confrelid, columns)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_constraint c
        WHERE c.contype = 'f'
          AND c.conrelid = expected.conrelid AND c.confrelid = expected.confrelid
          AND (SELECT string_agg(a.attname, ', ' ORDER BY k.ord)
               FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum) = expected.columns
    );
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing foreign keys: %', missing;
    END IF;

    -- Exactly one foreign key between assignment and assignment_field, the
    -- one the bootstrap made. A second one, in either direction, gives
    -- PostgREST two relationships between the views and turns
    -- `assignments?select=*,assignment_fields(*)` into a 300.
    SELECT string_agg(c.conname, ', ' ORDER BY c.conname) INTO missing
    FROM pg_constraint c
    WHERE c.contype = 'f'
      AND ((c.conrelid = 'data.assignment'::regclass AND c.confrelid = 'data.assignment_field'::regclass)
        OR (c.conrelid = 'data.assignment_field'::regclass AND c.confrelid = 'data.assignment'::regclass))
      AND c.conname <> 'assignment_field_assignment_slug_fkey';
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'unexpected foreign keys between assignment and assignment_field, which break PostgREST embedding: %', missing;
    END IF;

    -- Unique, on the template, and with the predicate that makes
    -- one-per-owner true: NULLs are distinct in a unique index, so without
    -- the WHERE every team row would pass the per-user key and the reverse.
    SELECT string_agg(expected.indexname, ', ' ORDER BY expected.indexname) INTO missing
    FROM (VALUES
        ('user_unique_github_user_id', '(github_user_id)', 'WHERE (github_user_id IS NOT NULL)'),
        ('user_unique_github_login', '(lower(github_login))', 'WHERE (github_login IS NOT NULL)'),
        ('assignment_repository_unique_user', '(user_id, template_slug)', 'WHERE (team_nickname IS NULL)'),
        ('assignment_repository_unique_team', '(team_nickname, template_slug)', 'WHERE (user_id IS NULL)'),
        ('assignment_repository_provisioning_unique_user', '(user_id, template_slug)', 'WHERE (team_nickname IS NULL)'),
        ('assignment_repository_provisioning_unique_team', '(team_nickname, template_slug)', 'WHERE (user_id IS NULL)')
    ) AS expected(indexname, columns, predicate)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_indexes i
        WHERE i.schemaname = 'data' AND i.indexname = expected.indexname
          AND i.indexdef LIKE 'CREATE UNIQUE INDEX%'
          AND i.indexdef LIKE '% ' || expected.columns || ' ' || expected.predicate
    );
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'missing unique indexes, or their columns or predicates: %', missing;
    END IF;

    -- Each trigger attached to the function it was written for, and enabled;
    -- a disabled trigger passes an existence check and enforces nothing.
    SELECT string_agg(expected.tgname, ', ' ORDER BY expected.tgname) INTO missing
    FROM (VALUES
        ('data.repository_template'::regclass, 'tg_repository_template_update_timestamps', 'data.update_updated_at_column()'::regprocedure),
        ('data.assignment_repository_provisioning'::regclass, 'tg_assignment_repository_provisioning_update_timestamps', 'data.update_updated_at_column()'::regprocedure)
    ) AS expected(tgrelid, tgname, tgfoid)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_trigger t
        WHERE t.tgrelid = expected.tgrelid AND t.tgname = expected.tgname
          AND t.tgfoid = expected.tgfoid AND t.tgenabled <> 'D' AND NOT t.tgisinternal
    );
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'triggers missing, disabled, or on the wrong function: %', missing;
    END IF;

    -- The URL-field triggers of the first cut must be gone with their columns.
    IF EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname IN ('tg_assignment_repository_url_field', 'tg_assignment_field_designated_url')
    ) THEN
        RAISE EXCEPTION 'the assignment URL-field triggers should not exist';
    END IF;

    SELECT string_agg(rel.name, ', ' ORDER BY rel.name) INTO missing
    FROM (VALUES ('data.repository_template'), ('data.assignment_repository_provisioning')) AS rel(name)
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_class
        WHERE oid = rel.name::regclass AND relrowsecurity
    );
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'row-level security disabled on: %', missing;
    END IF;

    -- The attempt policy: SELECT, for api, and scoped by the caller's
    -- identity. The template policy: all commands, for api, faculty-only on
    -- write, and scoped on the caller for reads.
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'data' AND tablename = 'assignment_repository_provisioning'
          AND policyname = 'assignment_repository_provisioning_access_policy'
          AND cmd = 'SELECT' AND roles = ARRAY['api']::name[]
          AND qual LIKE '%request.user_id()%'
    ) THEN
        RAISE EXCEPTION 'assignment_repository_provisioning_access_policy is not a SELECT policy for api scoped on request.user_id()';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = 'data' AND tablename = 'repository_template'
          AND policyname = 'repository_template_access_policy'
          AND cmd = 'ALL' AND roles = ARRAY['api']::name[]
          AND qual LIKE '%request.user_id()%'
          AND with_check LIKE '%faculty%'
    ) THEN
        RAISE EXCEPTION 'repository_template_access_policy is not an ALL policy for api, scoped on request.user_id() and faculty-only on write';
    END IF;

    -- The service RPCs: executable by app and by nobody human; the faculty
    -- bootstrap executable by faculty and nobody else. SECURITY DEFINER with
    -- a pinned search_path, owned by the migrator so they bypass the row
    -- policies as the table owner.
    SELECT string_agg(f.signature || ' for ' || r.rolname, ', '
        ORDER BY f.signature || r.rolname) INTO missing
    FROM (VALUES
        ('api.claim_repository_provisioning(text, int)', 'app'),
        ('api.record_repository_provisioning(int, text, bigint, text, text)', 'app'),
        ('api.finalize_repository_provisioning(int, bigint)', 'app'),
        ('api.touch_repository_provisioning_readiness(int, boolean)', 'app'),
        ('api.set_user_github_identity(int, bigint, text, boolean)', 'app'),
        ('api.import_github_logins(text, text)', 'faculty')
    ) AS f(signature, allowed)
    CROSS JOIN (VALUES ('anonymous'), ('student'), ('ta'), ('faculty'), ('app')) AS r(rolname)
    WHERE has_function_privilege(r.rolname, f.signature, 'EXECUTE') <> (r.rolname = f.allowed);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'execute privileges are wrong on: %', missing;
    END IF;

    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO missing
    FROM pg_proc p
    WHERE p.pronamespace = 'api'::regnamespace
      AND p.proname IN (
        'claim_repository_provisioning', 'record_repository_provisioning',
        'finalize_repository_provisioning', 'touch_repository_provisioning_readiness',
        'set_user_github_identity', 'import_github_logins'
      )
      AND NOT (
        p.prosecdef
        AND p.proconfig @> ARRAY['search_path=pg_catalog, data, request, pg_temp']
        AND pg_get_userbyid(p.proowner) = 'yelukerest_migrator'
      );
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'RPCs not SECURITY DEFINER with a pinned search_path under the migrator: %', missing;
    END IF;

    -- Read-only surfaces, and the one faculty write. A student, TA or
    -- faculty member holds SELECT and nothing else on the attempts and
    -- my_repositories views; faculty alone write templates; nobody but api
    -- touches a table.
    SELECT string_agg(r.grantee || ' ' || pr.name || ' on ' || rel.name, ', '
        ORDER BY r.grantee || pr.name || rel.name) INTO missing
    FROM (VALUES ('anonymous'), ('observer'), ('student'), ('ta'), ('faculty'), ('app')) AS r(grantee)
    CROSS JOIN (VALUES
        ('data.assignment_repository_provisioning'), ('data.repository_template'),
        ('api.repository_provisionings'), ('api.my_repositories'), ('api.repository_templates')
    ) AS rel(name)
    CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) AS pr(name)
    WHERE has_table_privilege(r.grantee, rel.name, pr.name) <> (
        rel.name LIKE 'api.%'
        AND r.grantee IN ('student', 'ta', 'faculty')
        AND (pr.name = 'SELECT' OR (rel.name = 'api.repository_templates' AND r.grantee = 'faculty'))
    );
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'unexpected privileges: %', missing;
    END IF;

    -- Faculty keep their writes on api.users column by column, and the three
    -- GitHub columns are not among them. Students never held a write here.
    SELECT string_agg(c.column_name || ' ' || pr.name, ', ' ORDER BY c.column_name || pr.name) INTO missing
    FROM (VALUES ('github_user_id'), ('github_login'), ('github_verified_at')) AS c(column_name)
    CROSS JOIN (VALUES ('INSERT'), ('UPDATE')) AS pr(name)
    WHERE has_column_privilege('faculty', 'api.users', c.column_name, pr.name)
       OR has_column_privilege('student', 'api.users', c.column_name, pr.name)
       OR has_column_privilege('ta', 'api.users', c.column_name, pr.name);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'GitHub identity columns are writable through api.users: %', missing;
    END IF;
    IF NOT has_column_privilege('faculty', 'api.users', 'nickname', 'UPDATE') THEN
        RAISE EXCEPTION 'faculty lost UPDATE on api.users';
    END IF;

    -- Floors, not equalities: see docs/platform-compatibility.md.
    IF NOT EXISTS (
        SELECT 1 FROM api.platform_version
        WHERE schema_compatibility_version >= 8 AND admin_api_version >= 15
    ) THEN
        RAISE EXCEPTION 'api.platform_version should report schema 8 or later and admin_api 15 or later';
    END IF;
END $$
