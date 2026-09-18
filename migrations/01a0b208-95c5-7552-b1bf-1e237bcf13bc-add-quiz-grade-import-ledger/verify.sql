-- Verify add-quiz-grade-import-ledger. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema. What must stay true is that the ledger is append-only and
-- faculty-only: the two tables exist under the migrator with row-level
-- security on; quiz_importer may insert and nothing more, under a policy
-- that requires a faculty or TA claim; api may select, for faculty; no role
-- but the migrator can update or delete; and the summary view is owned by
-- api, is a security barrier, and is readable by faculty alone. What the
-- import records is asserted behaviourally in
-- tests/db/yeluke-import_quiz_results.sql.
-- The tables: owned by the migrator, row security on and not forced.
SELECT
    1 / (
        SELECT (count(*) = 2)::int
        FROM pg_class c
        WHERE
            c.oid IN ('data.quiz_grade_import'::regclass, 'data.quiz_grade_import_item'::regclass)
            AND c.relkind = 'r'
            AND pg_get_userbyid(c.relowner) = 'yelukerest_migrator'
            AND c.relrowsecurity
            AND NOT c.relforcerowsecurity
    )
;
-- The item key and its link to the header.
SELECT
    1 / (
        SELECT COALESCE(array_agg(a.attname::text ORDER BY k.ordinality) = ARRAY['import_id', 'quiz_id', 'user_id'], false)::int
        FROM
            pg_constraint con
            CROSS JOIN unnest(con.conkey) WITH ORDINALITY k(attnum, ordinality)
            JOIN pg_attribute a ON a.attrelid = con.conrelid
            AND a.attnum = k.attnum
        WHERE
            con.conrelid = 'data.quiz_grade_import_item'::regclass
            AND con.contype = 'p'
    )
; SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_constraint con
        WHERE
            con.conrelid = 'data.quiz_grade_import_item'::regclass
            AND con.contype = 'f'
            AND con.confrelid = 'data.quiz_grade_import'::regclass
    )
;
-- Exact grants, read off each ACL: api SELECT and quiz_importer INSERT,
-- nothing else, nothing grantable, and no other grantee. The owner's implicit
-- entry is left out of the comparison; who the owner is was checked above.
SELECT
    1 / (
        SELECT (count(*) = 2)::int
        FROM
            pg_class c
            CROSS JOIN LATERAL (
                SELECT
                    array_agg(((a.grantee::regrole::text || ' ') || a.privilege_type) || CASE
                        WHEN a.is_grantable THEN ' WITH GRANT OPTION'
                        ELSE ''
                    END ORDER BY (a.grantee::regrole::text || ' ') || a.privilege_type COLLATE "C") AS grants
                FROM aclexplode(c.relacl) a
                WHERE a.grantee <> c.relowner
            ) acl
        WHERE
            c.oid IN ('data.quiz_grade_import'::regclass, 'data.quiz_grade_import_item'::regclass)
            AND acl.grants = ARRAY['api SELECT', 'quiz_importer INSERT']
    )
;
-- Append-only, effectively: no role but the migrator and superusers holds
-- UPDATE, DELETE or TRUNCATE on either table, through membership or
-- otherwise. Predefined roles are left out: pg_write_all_data would hold them
-- on every table by design, and nothing here grants it to anyone.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_roles r
            CROSS JOIN unnest(ARRAY['data.quiz_grade_import', 'data.quiz_grade_import_item']) t(rel)
            CROSS JOIN unnest(ARRAY['UPDATE', 'DELETE', 'TRUNCATE']) priv
        WHERE
            NOT r.rolsuper
            AND r.rolname NOT LIKE E'pg\\_%'
            AND r.rolname <> 'yelukerest_migrator'
            AND has_table_privilege(r.oid, t.rel, priv)
    )
;
-- The policies: exactly four on the two tables, each for one command and one
-- role, with these predicates (whitespace-normalized from pg_policies).
SELECT
    1 / (
        SELECT COALESCE(array_agg((((((((tablename || ' ') || cmd) || ' ') || roles::text) || ' USING ') || COALESCE(regexp_replace(qual, E'\\s+', ' ', 'g'), '-')) || ' CHECK ') || COALESCE(regexp_replace(with_check, E'\\s+', ' ', 'g'), '-') ORDER BY (tablename || ' ') || cmd COLLATE "C") = ARRAY['quiz_grade_import INSERT {quiz_importer} USING - CHECK (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text]))', 'quiz_grade_import SELECT {api} USING (request.user_role() = ''faculty''::text) CHECK -', 'quiz_grade_import_item INSERT {quiz_importer} USING - CHECK (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text]))', 'quiz_grade_import_item SELECT {api} USING (request.user_role() = ''faculty''::text) CHECK -'], false)::int
        FROM pg_policies
        WHERE
            schemaname = 'data'
            AND tablename IN ('quiz_grade_import', 'quiz_grade_import_item')
    )
;
-- The summary: a view owned by api, a security barrier, faculty SELECT and
-- no other privilege for any application role.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE
            n.nspname = 'api'
            AND c.relname = 'quiz_grade_imports'
            AND c.relkind = 'v'
            AND pg_get_userbyid(c.relowner) = 'api'
            AND c.reloptions @> ARRAY['security_barrier=true']
    )
; SELECT 1 / has_table_privilege('faculty', 'api.quiz_grade_imports', 'SELECT')::int
;
-- The summary reads both ledger tables, header and items, and carries at
-- least the columns the contract names. A later migration may add columns;
-- it may not drop these or cut the items out of the view. That the counts
-- agree with the items and that every header is listed is asserted
-- behaviourally in tests/db/yeluke-import_quiz_results.sql; matching the
-- view's source text here would break on a reformatting that changed
-- nothing.
SELECT
    1 / (
        SELECT (count(DISTINCT d.refobjid) = 2)::int
        FROM
            pg_rewrite w
            JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass
            AND d.objid = w.oid
            AND d.refclassid = 'pg_class'::regclass
        WHERE
            w.ev_class = 'api.quiz_grade_imports'::regclass
            AND d.refobjid IN ('data.quiz_grade_import'::regclass, 'data.quiz_grade_import_item'::regclass)
    )
; SELECT
    1 / (
        SELECT (count(*) = 15)::int
        FROM pg_attribute a
        WHERE
            a.attrelid = 'api.quiz_grade_imports'::regclass
            AND a.attnum > 0
            AND NOT a.attisdropped
            AND a.attname IN ('id', 'label', 'actor_user_id', 'actor_role', 'reason', 'dry_run', 'created_at', 'reverts_import_id', 'inserted_count', 'updated_count', 'unchanged_count', 'submission_created_count', 'attendance_inserted', 'attendance_updated', 'attendance_unchanged')
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_roles r
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) priv
        WHERE
            r.rolname IN ('anonymous', 'student', 'ta', 'observer', 'app', 'grant_consumer', 'grant_reader', 'authapp', 'quiz_importer')
            AND has_table_privilege(r.oid, 'api.quiz_grade_imports', priv)
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) priv
        WHERE has_table_privilege('faculty', 'api.quiz_grade_imports', priv)
    )
;
-- admin_api_version reached 12. A floor, not an equality: verification
-- re-runs against every later state of the schema, and the version only ever
-- grows.
SELECT
    1 / (
        SELECT (admin_api_version >= 12)::int
        FROM api.platform_version
    )
