-- Verify add-grant-consumer-role. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema. What must stay true is the privilege boundary: a grant
-- credential's role can execute exactly two functions and read nothing, and
-- the role that owns the reader can read only the tables the reader needs.
-- The privilege assertions compare against the exact intended set rather than
-- checking the needed ones are present, because presence checks pass under
-- drift. What the hook and the reader refuse is asserted behaviourally in
-- tests/db/yeluke-api-grants.sql.
-- Both roles exist, provisioned outside the migration graph, NOLOGIN and
-- without any cluster attribute that would let either act outside its grants.
SELECT
    1 / (
        SELECT (count(*) = 2)::int
        FROM pg_roles
        WHERE
            rolname IN ('grant_consumer', 'grant_reader')
            AND NOT rolcanlogin
            AND NOT rolsuper
            AND NOT rolcreaterole
            AND NOT rolcreatedb
            AND NOT rolreplication
            AND NOT rolbypassrls
    )
;
-- grant_consumer is a member of nothing: no inherited privilege can widen it.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_auth_members m
            JOIN pg_roles member ON member.oid = m.member
        WHERE member.rolname = 'grant_consumer'
    )
;
-- Who holds each role, directly or through another role. A membership is
-- the one route into the reader's unrestricted SELECT that no ACL check
-- below would see, so both sets are pinned transitively. grant_consumer:
-- only the authenticator (a login role directly holding anonymous), and at
-- least one such, or PostgREST cannot switch into it.
WITH RECURSIVE members AS (
    SELECT m.member
    FROM pg_auth_members m
    WHERE m.roleid = 'grant_consumer'::regrole
    UNION
    SELECT m.member
    FROM
        pg_auth_members m
        JOIN members ON m.roleid = members.member
)
SELECT
    1 / (
        SELECT
            (count(*) >= 1 AND bool_and(r.rolcanlogin
            AND EXISTS (
                SELECT
                FROM pg_auth_members am
                WHERE
                    am.member = r.oid
                    AND am.roleid = 'anonymous'::regrole
            )))::int
        FROM
            members
            JOIN pg_roles r ON r.oid = members.member
    )
;
-- grant_reader: the migrator and nobody else, directly or transitively.
WITH RECURSIVE members AS (
    SELECT m.member
    FROM pg_auth_members m
    WHERE m.roleid = 'grant_reader'::regrole
    UNION
    SELECT m.member
    FROM
        pg_auth_members m
        JOIN members ON m.roleid = members.member
)
SELECT
    1 / (
        SELECT (array_agg(r.rolname::text) = ARRAY['yelukerest_migrator'])::int
        FROM
            members
            JOIN pg_roles r ON r.oid = members.member
    )
;
-- grant_consumer's effective schema access among the application schemas is
-- USAGE on api alone (public and request are open to every role).
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM unnest(ARRAY['auth', 'data', 'pgjwt', 'settings']) s
        WHERE has_schema_privilege('grant_consumer', s, 'USAGE') OR has_schema_privilege('grant_consumer', s, 'CREATE')
    )
; SELECT
    1 / (has_schema_privilege('grant_consumer', 'api', 'USAGE')
    AND NOT has_schema_privilege('grant_consumer', 'api', 'CREATE'))::int
;
-- Effective EXECUTE on exactly the reader and the hook, across every function
-- overload in api. Effective, so PUBLIC and default privileges count.
SELECT
    1 / (
        SELECT (array_agg(((p.proname || '(') || oidvectortypes(p.proargtypes)) || ')' ORDER BY p.proname COLLATE "C") = ARRAY['check_request_jwt()', 'granted_submissions(text, integer, integer)'])::int
        FROM
            pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE
            n.nspname = 'api'
            AND has_function_privilege('grant_consumer', p.oid, 'EXECUTE')
    )
;
-- No relation privilege of any kind in api or data: every table-level
-- privilege PostgreSQL has, every column-level one (a column grant lives in
-- pg_attribute and is invisible to the table check), and every sequence one.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN']) priv
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
            AND has_table_privilege('grant_consumer', c.oid, priv)
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']) priv
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
            AND a.attnum > 0
            AND NOT a.attisdropped
            AND has_column_privilege('grant_consumer', c.oid, a.attnum, priv)
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) priv
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind = 'S'
            AND has_sequence_privilege('grant_consumer', c.oid, priv)
    )
;
-- grant_reader owns the reader, which is SECURITY DEFINER with a pinned
-- search_path, and holds exactly SELECT on the six tables the reader needs.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE
            n.nspname = 'api'
            AND p.proname = 'granted_submissions'
            AND p.prosecdef
            AND pg_get_userbyid(p.proowner) = 'grant_reader'
            AND EXISTS (
                SELECT 1
                FROM unnest(p.proconfig) c
                WHERE c LIKE 'search_path=%'
            )
    )
; SELECT
    1 / (
        SELECT (array_agg(c.oid::regclass::text ORDER BY c.oid::regclass::text COLLATE "C") = ARRAY['data."user"', 'data.api_grant', 'data.api_grant_assignment', 'data.api_grant_assignment_field', 'data.assignment_field_submission', 'data.assignment_submission'])::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind IN ('r', 'v', 'm', 'p', 'f', 'S')
            AND (has_table_privilege('grant_reader', c.oid, 'SELECT') OR has_table_privilege('grant_reader', c.oid, 'INSERT') OR has_table_privilege('grant_reader', c.oid, 'UPDATE') OR has_table_privilege('grant_reader', c.oid, 'DELETE'))
    )
;
-- ...and beyond SELECT on those six, nothing: no other table privilege
-- anywhere, no column privilege that is not that SELECT, no sequence
-- privilege.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN']) priv
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
            AND has_table_privilege('grant_reader', c.oid, priv)
            AND NOT (priv = 'SELECT'
            AND c.oid IN ('data."user"'::regclass, 'data.api_grant'::regclass, 'data.api_grant_assignment'::regclass, 'data.api_grant_assignment_field'::regclass, 'data.assignment_field_submission'::regclass, 'data.assignment_submission'::regclass))
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']) priv
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
            AND a.attnum > 0
            AND NOT a.attisdropped
            AND has_column_privilege('grant_reader', c.oid, a.attnum, priv)
            AND NOT (priv = 'SELECT'
            AND c.oid IN ('data."user"'::regclass, 'data.api_grant'::regclass, 'data.api_grant_assignment'::regclass, 'data.api_grant_assignment_field'::regclass, 'data.assignment_field_submission'::regclass, 'data.assignment_submission'::regclass))
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) priv
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind = 'S'
            AND has_sequence_privilege('grant_reader', c.oid, priv)
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM unnest(ARRAY['api', 'auth', 'data', 'pgjwt', 'settings']) s
        WHERE has_schema_privilege('grant_reader', s, 'CREATE')
    )
;
-- The three RLS tables admit grant_reader through its own SELECT policy;
-- without one, RLS would return it no rows and the reader would be silently
-- empty.
SELECT
    1 / (
        SELECT (count(*) = 3)::int
        FROM pg_policies
        WHERE
            schemaname = 'data'
            AND tablename IN ('assignment_submission', 'assignment_field_submission', 'user')
            AND policyname = 'api_grant_reader_policy'
            AND cmd = 'SELECT'
            AND roles = ARRAY['grant_reader']::name[]
    )
;
-- The issuer and the signer: faculty may create a grant, no other application
-- role may, and nobody but the owner may sign.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE
            n.nspname = 'api'
            AND p.proname = 'create_api_grant'
            AND p.prosecdef
            AND pg_get_userbyid(p.proowner) = 'yelukerest_migrator'
    )
; SELECT 1 / has_function_privilege('faculty', 'api.create_api_grant(text, jsonb, timestamp with time zone)', 'EXECUTE')::int
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_roles r
        WHERE
            r.rolname IN ('anonymous', 'student', 'ta', 'observer', 'app', 'grant_consumer', 'grant_reader')
            AND has_function_privilege(r.oid, 'api.create_api_grant(text, jsonb, timestamp with time zone)', 'EXECUTE')
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_roles r
        WHERE
            r.rolname <> 'yelukerest_migrator'
            AND NOT r.rolsuper
            AND has_function_privilege(r.oid, 'auth.sign_grant_jwt(int, timestamp with time zone, text)', 'EXECUTE')
    )
